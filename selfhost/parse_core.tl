;; parse_core.tl - Main-less Sexpr -> Expr parser shared by selfhost drivers.
;;
;; The runnable `parse.tl` demo used to contain these definitions directly.
;; Keeping them here lets other drivers reuse the parser without importing a
;; second `main`.
(import "../stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "../stdlib/io.tl")

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
    [e1 : SymI64Env (sym-i64-bind e0 "let" (parse-tag-let))]
    [e2 : SymI64Env (sym-i64-bind e1 "if" (parse-tag-if))]
    [e3 : SymI64Env (sym-i64-bind e2 "while" (parse-tag-while))]
    [e4 : SymI64Env (sym-i64-bind e3 "print" (parse-tag-print))]
    [e5 : SymI64Env (sym-i64-bind e4 "set!" (parse-tag-set))]
    [e6 : SymI64Env (sym-i64-bind e5 "begin" (parse-tag-begin))]
    [e7 : SymI64Env (sym-i64-bind e6 "+" (parse-tag-add))]
    [e8 : SymI64Env (sym-i64-bind e7 "-" (parse-tag-sub))]
    [e9 : SymI64Env (sym-i64-bind e8 "*" (parse-tag-mul))]
    [e10 : SymI64Env (sym-i64-bind e9 "<" (parse-tag-lt))]
    [e11 : SymI64Env (sym-i64-bind e10 "=" (parse-tag-eq))]
    [e12 : SymI64Env (sym-i64-bind e11 "<=" (parse-tag-le))]
    [e13 : SymI64Env (sym-i64-bind e12 ">" (parse-tag-gt))]
    [e14 : SymI64Env (sym-i64-bind e13 ">=" (parse-tag-ge))]
    [e15 : SymI64Env (sym-i64-bind e14 "!=" (parse-tag-ne))]
    [e16 : SymI64Env (sym-i64-bind e15 "and" (parse-tag-and))]
    [e17 : SymI64Env (sym-i64-bind e16 "or" (parse-tag-or))]
    (sym-i64-bind e17 "not" (parse-tag-not))))

(define (parse-dispatch-tag [dispatch : SymI64Env] [op : String]) : i64
  (match (sym-i64-lookup dispatch op)
    [(SomeI64 tag) tag]
    [(NoneI64) (parse-tag-call)]))

(define (parse-op-tag [tag : i64]) : BinOp
  (core/cond
    (= tag (parse-tag-add))
    (OpAdd)
    (= tag (parse-tag-sub))
    (OpSub)
    (= tag (parse-tag-mul))
    (OpMul)
    (= tag (parse-tag-lt))
    (OpLt)
    (= tag (parse-tag-eq))
    (OpEq)
    (= tag (parse-tag-le))
    (OpLe)
    (= tag (parse-tag-gt))
    (OpGt)
    (= tag (parse-tag-ge))
    (OpGe)
    (= tag (parse-tag-ne))
    (OpNe)
    (= tag (parse-tag-and))
    (OpAnd)
    (= tag (parse-tag-or))
    (OpOr)
    (begin
      (panic "parse: unknown operator")
      (OpAdd))))

(define (parse-op [op : String]) : BinOp
  (parse-op-tag (parse-dispatch-tag (parse-dispatch-env) op)))

(define (is-binary-tag [tag : i64]) : bool
  (core/cond
    (= tag (parse-tag-add))
    true
    (= tag (parse-tag-sub))
    true
    (= tag (parse-tag-mul))
    true
    (= tag (parse-tag-lt))
    true
    (= tag (parse-tag-eq))
    true
    (= tag (parse-tag-le))
    true
    (= tag (parse-tag-gt))
    true
    (= tag (parse-tag-ge))
    true
    (= tag (parse-tag-ne))
    true
    (= tag (parse-tag-and))
    true
    (= tag (parse-tag-or))
    true
    false))

(define (is-binary-op [op : String]) : bool
  (is-binary-tag (parse-dispatch-tag (parse-dispatch-env) op)))

(define (parse-binary
  [dispatch : SymI64Env]
  [op : BinOp]
  [rest : Sexpr]
  [tag : i64]) : ResultExpr
  (match rest
    [(SCons a b-tail)
      (match (box-get b-tail)
        [(SCons b end)
          (match (box-get end)
            [(SNil)
              (match (parse-with-dispatch dispatch (box-get a))
                [(OkExpr left)
                  (match (parse-with-dispatch dispatch (box-get b))
                    [(OkExpr right) (OkExpr (EBin op (box left) (box right)))]
                    [(ErrExpr message) (ErrExpr message)])]
                [(ErrExpr message) (ErrExpr message)])]
            [_
              (if (= tag (parse-tag-and))
                (ErrExpr "parse: malformed and")
                (if (= tag (parse-tag-or))
                  (ErrExpr "parse: malformed or")
                  (ErrExpr "parse: malformed binary expression")))])]
        [_
          (if (= tag (parse-tag-and))
            (ErrExpr "parse: malformed and")
            (if (= tag (parse-tag-or))
              (ErrExpr "parse: malformed or")
              (ErrExpr "parse: malformed binary expression")))])]
    [_
      (if (= tag (parse-tag-and))
        (ErrExpr "parse: malformed and")
        (if (= tag (parse-tag-or))
          (ErrExpr "parse: malformed or")
          (ErrExpr "parse: malformed binary expression")))]))

(define (parse-not [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons arg end)
      (match (box-get end)
        [(SNil)
          (match (parse-with-dispatch dispatch (box-get arg))
            [(OkExpr parsed-arg) (OkExpr (ENot (box parsed-arg)))]
            [(ErrExpr message) (ErrExpr message)])]
        [_ (ErrExpr "parse: malformed not")])]
    [_ (ErrExpr "parse: malformed not")]))

;; parse-let: single- or multi-binding let, desugared into nested ELet nodes
;; so later bindings can see earlier ones (sequential let* semantics).
(define (parse-let-bindings
  [dispatch : SymI64Env]
  [bindings : Sexpr]
  [body : Expr]) : ResultExpr
  (match bindings
    [(SNil) (OkExpr body)]
    [(SCons binding rest)
      (match (box-get binding)
        [(SCons name-node value-tail)
          (match (box-get name-node)
            [(SSym name)
              (match (box-get value-tail)
                [(SCons value end)
                  (match (box-get end)
                    [(SNil)
                      (match (parse-with-dispatch dispatch (box-get value))
                        [(OkExpr parsed-value)
                          (match (parse-let-bindings
                            dispatch
                            (box-get rest)
                            body)
                            [(OkExpr parsed-rest)
                              (OkExpr
                                (ELet name (box parsed-value) (box parsed-rest)))]
                            [(ErrExpr message) (ErrExpr message)])]
                        [(ErrExpr message) (ErrExpr message)])]
                    [_ (ErrExpr "parse: malformed let binding")])]
                [_ (ErrExpr "parse: malformed let binding")])]
            [_ (ErrExpr "parse: malformed let binding")])]
        [_ (ErrExpr "parse: malformed let binding")])]
    [_ (ErrExpr "parse: malformed let binding")]))

(define (parse-let [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons bindings body-tail)
      (match (box-get body-tail)
        [(SCons body end)
          (match (box-get end)
            [(SNil)
              (match (parse-with-dispatch dispatch (box-get body))
                [(OkExpr parsed-body)
                  (parse-let-bindings dispatch (box-get bindings) parsed-body)]
                [(ErrExpr message) (ErrExpr message)])]
            [_ (ErrExpr "parse: malformed let")])]
        [_ (ErrExpr "parse: malformed let")])]
    [_ (ErrExpr "parse: malformed let")]))

(define (parse-set [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons name-node value-tail)
      (match (box-get name-node)
        [(SSym name)
          (match (box-get value-tail)
            [(SCons value end)
              (match (box-get end)
                [(SNil)
                  (match (parse-with-dispatch dispatch (box-get value))
                    [(OkExpr parsed-value)
                      (OkExpr (ESet name (box parsed-value)))]
                    [(ErrExpr message) (ErrExpr message)])]
                [_ (ErrExpr "parse: malformed set!")])]
            [_ (ErrExpr "parse: malformed set!")])]
        [_ (ErrExpr "parse: malformed set!")])]
    [_ (ErrExpr "parse: malformed set!")]))

(define (parse-if [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c then-tail)
      (match (box-get then-tail)
        [(SCons t else-tail)
          (match (box-get else-tail)
            [(SCons e end)
              (match (box-get end)
                [(SNil)
                  (match (parse-with-dispatch dispatch (box-get c))
                    [(OkExpr parsed-c)
                      (match (parse-with-dispatch dispatch (box-get t))
                        [(OkExpr parsed-t)
                          (match (parse-with-dispatch dispatch (box-get e))
                            [(OkExpr parsed-e)
                              (OkExpr
                                (EIf
                                  (box parsed-c)
                                  (box parsed-t)
                                  (box parsed-e)))]
                            [(ErrExpr message) (ErrExpr message)])]
                        [(ErrExpr message) (ErrExpr message)])]
                    [(ErrExpr message) (ErrExpr message)])]
                [_ (ErrExpr "parse: malformed if")])]
            [_ (ErrExpr "parse: malformed if")])]
        [_ (ErrExpr "parse: malformed if")])]
    [_ (ErrExpr "parse: malformed if")]))

(define (parse-while [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c body-tail)
      (match (box-get body-tail)
        [(SCons body end)
          (match (box-get end)
            [(SNil)
              (match (parse-with-dispatch dispatch (box-get c))
                [(OkExpr parsed-c)
                  (match (parse-with-dispatch dispatch (box-get body))
                    [(OkExpr parsed-body)
                      (OkExpr (EWhile (box parsed-c) (box parsed-body)))]
                    [(ErrExpr message) (ErrExpr message)])]
                [(ErrExpr message) (ErrExpr message)])]
            [_ (ErrExpr "parse: malformed while")])]
        [_ (ErrExpr "parse: malformed while")])]
    [_ (ErrExpr "parse: malformed while")]))

(define (parse-print [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons arg end)
      (match (box-get end)
        [(SNil)
          (match (parse-with-dispatch dispatch (box-get arg))
            [(OkExpr parsed-arg) (OkExpr (EPrint (box parsed-arg)))]
            [(ErrExpr message) (ErrExpr message)])]
        [_ (ErrExpr "parse: malformed print")])]
    [_ (ErrExpr "parse: malformed print")]))

(define (parse-begin [dispatch : SymI64Env] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SNil) (ErrExpr "parse: empty begin")]
    [(SCons _ _)
      (match (parse-args dispatch rest)
        [(OkExprList args) (OkExpr (EBegin (box args)))]
        [(ErrExprList message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed begin")]))

(define (parse-args [dispatch : SymI64Env] [s : Sexpr]) : ResultExprList
  (match s
    [(SNil) (OkExprList ELNil)]
    [(SCons a d)
      (match (parse-with-dispatch dispatch (box-get a))
        [(OkExpr parsed-a)
          (match (parse-args dispatch (box-get d))
            [(OkExprList parsed-d)
              (OkExprList (ELCons parsed-a (box parsed-d)))]
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
    [(SCons head rest)
      (match (box-get head)
        [(SSym op)
          (let
            [tag : i64 (parse-dispatch-tag dispatch op)]
            (core/cond
              (= tag (parse-tag-let))
              (parse-let dispatch (box-get rest))
              (= tag (parse-tag-if))
              (parse-if dispatch (box-get rest))
              (= tag (parse-tag-while))
              (parse-while dispatch (box-get rest))
              (= tag (parse-tag-print))
              (parse-print dispatch (box-get rest))
              (= tag (parse-tag-set))
              (parse-set dispatch (box-get rest))
              (= tag (parse-tag-begin))
              (parse-begin dispatch (box-get rest))
              (= tag (parse-tag-not))
              (parse-not dispatch (box-get rest))
              (is-binary-tag tag)
              (parse-binary dispatch (parse-op-tag tag) (box-get rest) tag)
              (match (parse-args dispatch (box-get rest))
                [(OkExprList args) (OkExpr (ECall op (box args)))]
                [(ErrExprList message) (ErrExpr message)])))]
        [_ (ErrExpr "parse: malformed expression")])]
    [_ (ErrExpr "parse: malformed expression")]))

(define (parse [s : Sexpr]) : ResultExpr
  (parse-with-dispatch (parse-dispatch-env) s))

(define (parse-params [s : Sexpr]) : ResultStrList
  (match s
    [(SNil) (OkStrList SLNil)]
    [(SCons name-node rest)
      (match (box-get name-node)
        [(SSym name)
          (match (parse-params (box-get rest))
            [(OkStrList parsed-rest)
              (OkStrList (SLCons name (box parsed-rest)))]
            [(ErrStrList message) (ErrStrList message)])]
        [_ (ErrStrList "parse: malformed parameter list")])]
    [_ (ErrStrList "parse: malformed parameter list")]))

(define (is-define-form [s : Sexpr]) : bool
  (match s
    [(SCons head-node _)
      (match (box-get head-node)
        [(SSym head) (string-eq head "define")]
        [_ false])]
    [_ false]))

(define (parse-define-header
  [dispatch : SymI64Env]
  [header : Sexpr]
  [body : Sexpr]) : ResultItem
  (match header
    [(SCons name-node params)
      (match (box-get name-node)
        [(SSym name)
          (match (parse-params (box-get params))
            [(OkStrList parsed-params)
              (match (parse-with-dispatch dispatch body)
                [(OkExpr parsed-body)
                  (OkItem (IDefFn name parsed-params parsed-body))]
                [(ErrExpr message) (ErrItem message)])]
            [(ErrStrList message) (ErrItem message)])]
        [_ (ErrItem "parse: malformed define header")])]
    [_ (ErrItem "parse: malformed define header")]))

(define (parse-define-rest-body
  [dispatch : SymI64Env]
  [header : Sexpr]
  [after-header : Sexpr]) : ResultItem
  (match after-header
    [(SCons body end)
      (match (box-get end)
        [(SNil) (parse-define-header dispatch header (box-get body))]
        [_ (ErrItem "parse: expected end of list")])]
    [(SCons _ _) (ErrItem "parse: expected end of list")]
    [(SNil) (ErrItem "parse: expected non-empty list")]
    [_ (ErrItem "parse: expected list tail")]))

(define (parse-define-rest [dispatch : SymI64Env] [rest : Sexpr]) : ResultItem
  (match rest
    [(SCons header after-header)
      (parse-define-rest-body dispatch (box-get header) (box-get after-header))]
    [(SNil) (ErrItem "parse: expected non-empty list")]
    [_ (ErrItem "parse: expected list tail")]))

(define (parse-item [dispatch : SymI64Env] [s : Sexpr]) : ResultItem
  (match s
    [(SCons head-node rest)
      (match (box-get head-node)
        [(SSym head)
          (if (string-eq head "define")
            (parse-define-rest dispatch (box-get rest))
            (ErrItem "parse: expected define"))]
        [_ (ErrItem "parse: malformed item")])]
    [_ (ErrItem "parse: malformed item")]))

(define (item-list-append-one [items : ItemList] [item : Item]) : ItemList
  (match items
    [(ILNil) (ILCons item (box ILNil))]
    [(ILCons head rest)
      (ILCons head (box (item-list-append-one (box-get rest) item)))]))

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
    [dispatch : SymI64Env (parse-dispatch-env)]
    (begin
      (array-set! cur 0 0)
      (parse-program-forms dispatch toks cur ILNil))))