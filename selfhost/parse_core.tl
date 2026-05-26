;; parse_core.tl - Main-less Sexpr -> Expr parser shared by selfhost drivers.
;;
;; The runnable `parse.tl` demo used to contain these definitions directly.
;; Keeping them here lets other drivers reuse the parser without importing a
;; second `main`.
(import "sym_i64_env.tl")

(import "emit_core.tl")

(import "read.tl")

(define (parse-tag-call) : i64
  0)

(define (parse-tag-let) : i64
  1)

(define (parse-tag-if) : i64
  2)

(define (parse-tag-while) : i64
  3)

(define (parse-tag-print) : i64
  4)

(define (parse-tag-set) : i64
  5)

(define (parse-tag-begin) : i64
  6)

(define (parse-tag-add) : i64
  10)

(define (parse-tag-sub) : i64
  11)

(define (parse-tag-mul) : i64
  12)

(define (parse-tag-lt) : i64
  13)

(define (parse-tag-eq) : i64
  14)

(define (parse-tag-le) : i64
  15)

(define (parse-tag-gt) : i64
  16)

(define (parse-tag-ge) : i64
  17)

(define (parse-tag-ne) : i64
  18)

(define (parse-tag-and) : i64
  19)

(define (parse-tag-or) : i64
  20)

(define (parse-tag-not) : i64
  21)

(define (parse-dispatch-env) : SymI64Env
  (let
    [e0 : SymI64Env (sym-i64-empty)]
    (let
      [e1 : SymI64Env (sym-i64-bind e0 "let" (parse-tag-let))]
      (let
        [e2 : SymI64Env (sym-i64-bind e1 "if" (parse-tag-if))]
        (let
          [e3 : SymI64Env (sym-i64-bind e2 "while" (parse-tag-while))]
          (let
            [e4 : SymI64Env (sym-i64-bind e3 "print" (parse-tag-print))]
            (let
              [e5 : SymI64Env (sym-i64-bind e4 "set!" (parse-tag-set))]
              (let
                [e6 : SymI64Env (sym-i64-bind e5 "begin" (parse-tag-begin))]
                (let
                  [e7 : SymI64Env (sym-i64-bind e6 "+" (parse-tag-add))]
                  (let
                    [e8 : SymI64Env (sym-i64-bind e7 "-" (parse-tag-sub))]
                    (let
                      [e9 : SymI64Env (sym-i64-bind e8 "*" (parse-tag-mul))]
                      (let
                        [e10 : SymI64Env (sym-i64-bind e9 "<" (parse-tag-lt))]
                        (let
                          [e11 : SymI64Env
                            (sym-i64-bind e10 "=" (parse-tag-eq))]
                          (let
                            [e12 : SymI64Env
                              (sym-i64-bind e11 "<=" (parse-tag-le))]
                            (let
                              [e13 : SymI64Env
                                (sym-i64-bind e12 ">" (parse-tag-gt))]
                              (let
                                [e14 : SymI64Env
                                  (sym-i64-bind e13 ">=" (parse-tag-ge))]
                                (let
                                  [e15 : SymI64Env
                                    (sym-i64-bind e14 "!=" (parse-tag-ne))]
                                  (let
                                    [e16 : SymI64Env
                                      (sym-i64-bind e15 "and" (parse-tag-and))]
                                    (let
                                      [e17 : SymI64Env
                                        (sym-i64-bind e16 "or" (parse-tag-or))]
                                      (sym-i64-bind e17 "not" (parse-tag-not)))))))))))))))))))))

(define (parse-dispatch-tag [dispatch : SymI64Env] [op : String]) : i64
  (match (sym-i64-lookup dispatch op)
    [(SomeI64 tag) tag]
    [(NoneI64) (parse-tag-call)]))

(define (parse-op-tag [tag : i64]) : BinOp
  (cond
    [(= tag (parse-tag-add)) (OpAdd)]
    [(= tag (parse-tag-sub)) (OpSub)]
    [(= tag (parse-tag-mul)) (OpMul)]
    [(= tag (parse-tag-lt)) (OpLt)]
    [(= tag (parse-tag-eq)) (OpEq)]
    [(= tag (parse-tag-le)) (OpLe)]
    [(= tag (parse-tag-gt)) (OpGt)]
    [(= tag (parse-tag-ge)) (OpGe)]
    [(= tag (parse-tag-ne)) (OpNe)]
    [(= tag (parse-tag-and)) (OpAnd)]
    [(= tag (parse-tag-or)) (OpOr)]
    [else
      (begin
        (panic "parse: unknown operator")
        (OpAdd))]))

(define (parse-op [op : String]) : BinOp
  (parse-op-tag (parse-dispatch-tag (parse-dispatch-env) op)))

(define (is-binary-tag [tag : i64]) : bool
  (cond
    [(= tag (parse-tag-add)) true]
    [(= tag (parse-tag-sub)) true]
    [(= tag (parse-tag-mul)) true]
    [(= tag (parse-tag-lt)) true]
    [(= tag (parse-tag-eq)) true]
    [(= tag (parse-tag-le)) true]
    [(= tag (parse-tag-gt)) true]
    [(= tag (parse-tag-ge)) true]
    [(= tag (parse-tag-ne)) true]
    [(= tag (parse-tag-and)) true]
    [(= tag (parse-tag-or)) true]
    [else false]))

(define (is-binary-op [op : String]) : bool
  (is-binary-tag (parse-dispatch-tag (parse-dispatch-env) op)))

(define (parse-binary
  [dispatch : SymI64Env]
  [op : BinOp]
  [rest : Sexpr]
  [tag : i64]) : ResultExpr
  (match rest
    [(SCons a (SCons b (SNil)))
      (match (parse-with-dispatch dispatch a)
        [(OkExpr left)
          (match (parse-with-dispatch dispatch b)
            [(OkExpr right) (OkExpr (EBin op left right))]
            [(ErrExpr message) (ErrExpr message)])]
        [(ErrExpr message) (ErrExpr message)])]
    [_
      (if (= tag (parse-tag-and))
        (ErrExpr "parse: malformed and")
        (if (= tag (parse-tag-or))
          (ErrExpr "parse: malformed or")
          (ErrExpr "parse: malformed binary expression")))]))

(define (parse-not [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons arg (SNil))
      (match (parse-with-dispatch dispatch arg)
        [(OkExpr parsed-arg) (OkExpr (ENot parsed-arg))]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed not")]))

;; parse-let: single- or multi-binding let, desugared into nested ELet nodes
;; so later bindings can see earlier ones (sequential let* semantics).
(define (parse-let-bindings
  [dispatch : SymI64Env]
  [bindings : Sexpr]
  [body : Expr]) : ResultExpr
  (match bindings
    [(SNil) (OkExpr body)]
    [(SCons (SCons (SSym name) (SCons value (SNil))) rest)
      (match (parse-with-dispatch dispatch value)
        [(OkExpr parsed-value)
          (match (parse-let-bindings dispatch rest body)
            [(OkExpr parsed-rest) (OkExpr (ELet name parsed-value parsed-rest))]
            [(ErrExpr message) (ErrExpr message)])]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed let binding")]))

(define (parse-let [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons bindings (SCons body (SNil)))
      (match (parse-with-dispatch dispatch body)
        [(OkExpr parsed-body)
          (parse-let-bindings dispatch bindings parsed-body)]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed let")]))

(define (parse-set [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons (SSym name) (SCons value (SNil)))
      (match (parse-with-dispatch dispatch value)
        [(OkExpr parsed-value) (OkExpr (ESet name parsed-value))]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed set!")]))

(define (parse-if [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
      (match (parse-with-dispatch dispatch c)
        [(OkExpr parsed-c)
          (match (parse-with-dispatch dispatch t)
            [(OkExpr parsed-t)
              (match (parse-with-dispatch dispatch e)
                [(OkExpr parsed-e) (OkExpr (EIf parsed-c parsed-t parsed-e))]
                [(ErrExpr message) (ErrExpr message)])]
            [(ErrExpr message) (ErrExpr message)])]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed if")]))

(define (parse-while [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c (SCons body (SNil)))
      (match (parse-with-dispatch dispatch c)
        [(OkExpr parsed-c)
          (match (parse-with-dispatch dispatch body)
            [(OkExpr parsed-body) (OkExpr (EWhile parsed-c parsed-body))]
            [(ErrExpr message) (ErrExpr message)])]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed while")]))

(define (parse-print [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons arg (SNil))
      (match (parse-with-dispatch dispatch arg)
        [(OkExpr parsed-arg) (OkExpr (EPrint parsed-arg))]
        [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed print")]))

(define (parse-begin [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SNil) (ErrExpr "parse: empty begin")]
    [(SCons _ _)
      (match (parse-args dispatch rest)
        [(OkExprList args) (OkExpr (EBegin args))]
        [(ErrExprList message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed begin")]))

(define (parse-args [dispatch : SymI64Env] [s : Sexpr]) : ResultExprList
  (match s
    [(SNil) (OkExprList ELNil)]
    [(SCons a d)
      (match (parse-with-dispatch dispatch a)
        [(OkExpr parsed-a)
          (match (parse-args dispatch d)
            [(OkExprList parsed-d) (OkExprList (ELCons parsed-a parsed-d))]
            [(ErrExprList message) (ErrExprList message)])]
        [(ErrExpr message) (ErrExprList message)])]
    [_ (ErrExprList "parse: malformed argument list")]))

(define (parse-with-dispatch [dispatch : SymI64Env] [s : Sexpr]) : ResultExpr
  (match s
    [(SInt n) (OkExpr (EInt n))]
    [(SSym name) (OkExpr (EVar name))]
    [(SStr s) (OkExpr (EStr s))]
    [(SFloat _) (ErrExpr "parse: unsupported float literal")]
    [(SChar _) (ErrExpr "parse: unsupported char literal")]
    [(SCons (SSym op) rest)
      (let
        [tag : i64 (parse-dispatch-tag dispatch op)]
        (if (= tag (parse-tag-let))
          (parse-let dispatch rest)
          (if (= tag (parse-tag-if))
            (parse-if dispatch rest)
            (if (= tag (parse-tag-while))
              (parse-while dispatch rest)
              (if (= tag (parse-tag-print))
                (parse-print dispatch rest)
                (if (= tag (parse-tag-set))
                  (parse-set dispatch rest)
                  (if (= tag (parse-tag-begin))
                    (parse-begin dispatch rest)
                    (if (= tag (parse-tag-not))
                      (parse-not dispatch rest)
                      (if (is-binary-tag tag)
                        (parse-binary dispatch (parse-op-tag tag) rest tag)
                        (match (parse-args dispatch rest)
                          [(OkExprList args) (OkExpr (ECall op args))]
                          [(ErrExprList message) (ErrExpr message)]))))))))))]
    [_ (ErrExpr "parse: malformed expression")]))

(define (parse [s : Sexpr]) : ResultExpr
  (parse-with-dispatch (parse-dispatch-env) s))

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

(define (parse-define-header
  [dispatch : SymI64Env]
  [header : Sexpr]
  [body : Sexpr]) : ResultItem
  (match header
    [(SCons (SSym name) params)
      (match (parse-params params)
        [(OkStrList parsed-params)
          (match (parse-with-dispatch dispatch body)
            [(OkExpr parsed-body)
              (OkItem (IDefFn name parsed-params parsed-body))]
            [(ErrExpr message) (ErrItem message)])]
        [(ErrStrList message) (ErrItem message)])]
    [_ (ErrItem "parse: malformed define header")]))

(define (parse-define-rest-body
  [dispatch : SymI64Env]
  [header : Sexpr]
  [after-header : Sexpr]) : ResultItem
  (match after-header
    [(SCons body (SNil)) (parse-define-header dispatch header body)]
    [(SCons _ _) (ErrItem "parse: expected end of list")]
    [(SNil) (ErrItem "parse: expected non-empty list")]
    [_ (ErrItem "parse: expected list tail")]))

(define (parse-define-rest [dispatch : SymI64Env] [rest : Sexpr]) : ResultItem
  (match rest
    [(SCons header after-header)
      (parse-define-rest-body dispatch header after-header)]
    [(SNil) (ErrItem "parse: expected non-empty list")]
    [_ (ErrItem "parse: expected list tail")]))

(define (parse-item [dispatch : SymI64Env] [s : Sexpr]) : ResultItem
  (match s
    [(SCons (SSym head) rest)
      (if (string-eq head "define")
        (parse-define-rest dispatch rest)
        (ErrItem "parse: expected define"))]
    [_ (ErrItem "parse: malformed item")]))

(define (item-list-append-one [items : ItemList] [item : Item]) : ItemList
  (match items
    [(ILNil) (ILCons item ILNil)]
    [(ILCons head rest) (ILCons head (item-list-append-one rest item))]))

(define (parse-program-forms
  [dispatch : SymI64Env]
  [toks : (Array Token)]
  [cur : (Array i64)]
  [defs : ItemList]) : ResultParsedProgram
  (let
    [form : Sexpr (read-form toks cur)]
    (if (= (peek-tag toks cur) (tag-end))
      (if (is-define-form form)
        (ErrParsedProgram "parse: missing final expression")
        (match (parse-with-dispatch dispatch form)
          [(OkExpr expr) (OkParsedProgram (PProgram defs expr))]
          [(ErrExpr message) (ErrParsedProgram message)]))
      (if (is-define-form form)
        (match (parse-item dispatch form)
          [(OkItem item)
            (parse-program-forms
              dispatch
              toks
              cur
              (item-list-append-one defs item))]
          [(ErrItem message) (ErrParsedProgram message)])
        (ErrParsedProgram "parse: non-final form must be define")))))

(define (parse-program [toks : (Array Token)]) : ResultParsedProgram
  (let
    [cur : (Array i64) (make-array i64 1)]
    (let
      [dispatch : SymI64Env (parse-dispatch-env)]
      (begin
        (array-set! cur 0 0)
        (parse-program-forms dispatch toks cur ILNil)))))