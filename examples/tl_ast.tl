;; tl_ast.tl - Sexpr -> compiler AST parser for the M1 self-hosting slice (#154).

(import "tl_ast_types.tl")
(import "tl_read.tl")

(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SCons a _) a]
    [_ (begin (panic "ast: expected non-empty list") SNil)]))

(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SCons _ d) d]
    [_ (begin (panic "ast: expected list tail") SNil)]))

(define (sexpr-expect-nil [s : Sexpr]) : unit
  (match s
    [(SNil) (print-string "")]
    [_ (panic "ast: expected end of list")]))

(define (parse-binary [op : BinOp] [rest : Sexpr]) : Expr
  (let ([a : Sexpr (sexpr-head rest)]
        [after-a : Sexpr (sexpr-tail rest)])
    (let ([b : Sexpr (sexpr-head after-a)]
          [after-b : Sexpr (sexpr-tail after-a)])
      (begin
        (sexpr-expect-nil after-b)
        (EBin op (parse-expr a) (parse-expr b))))))

(define (parse-let [rest : Sexpr]) : Expr
  (match rest
    [(SCons (SCons (SCons (SSym name) (SCons value (SNil))) (SNil))
            (SCons body (SNil)))
     (ELet name (parse-expr value) (parse-expr body))]
    [_ (begin (panic "ast: malformed let") (EInt 0))]))

(define (parse-args [s : Sexpr]) : ExprList
  (match s
    [(SNil) ELNil]
    [(SCons a d) (ELCons (parse-expr a) (parse-args d))]
    [_ (begin (panic "ast: malformed argument list") ELNil)]))

(define (parse-expr [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SCons (SSym op) rest)
     (if (string-eq op "+")
         (parse-binary (OpAdd) rest)
         (if (string-eq op "-")
             (parse-binary (OpSub) rest)
             (if (string-eq op "*")
                 (parse-binary (OpMul) rest)
                 (if (string-eq op "let")
                     (parse-let rest)
                     (ECall op (parse-args rest))))))]
    [_ (begin (panic "ast: malformed expression") (EInt 0))]))

(define (parse-params [s : Sexpr]) : StrList
  (match s
    [(SNil) SLNil]
    [(SCons (SSym name) rest) (SLCons name (parse-params rest))]
    [_ (begin (panic "ast: malformed parameter list") SLNil)]))

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
                  (IDefFn name (parse-params params) (parse-expr body))]
                 [_ (begin (panic "ast: malformed define header")
                           (IDefFn "" SLNil (EInt 0)))]))))
         (begin (panic "ast: expected define") (IDefFn "" SLNil (EInt 0))))]
    [_ (begin (panic "ast: malformed item") (IDefFn "" SLNil (EInt 0)))]))

(define (op-score [op : BinOp]) : i64
  (match op
    [(OpAdd) 10]
    [(OpSub) 20]
    [(OpMul) 30]))

(define (expr-list-score [xs : ExprList]) : i64
  (match xs
    [(ELNil) 0]
    [(ELCons e rest) (+ (expr-score e) (expr-list-score rest))]))

(define (str-list-count [xs : StrList]) : i64
  (match xs
    [(SLNil) 0]
    [(SLCons _ rest) (+ 1 (str-list-count rest))]))

(define (expr-score [e : Expr]) : i64
  (match e
    [(EInt n) n]
    [(EVar name) (string-length name)]
    [(EBin op a b) (+ (op-score op) (+ (expr-score a) (expr-score b)))]
    [(ELet name value body)
     (+ (string-length name) (+ (expr-score value) (expr-score body)))]
    [(ECall name args) (+ (string-length name) (expr-list-score args))]))

(define (item-score [i : Item]) : i64
  (match i
    [(IDefFn name params body)
     (+ (string-length name) (+ (str-list-count params) (expr-score body)))]))

(define (main) : i64
  (+ (+ (expr-score (parse-expr (read (lex "(+ 1 (* 2 3))"))))
        (item-score (parse-item (read (lex "(define (main) (+ 1 (* 2 3)))")))))
     (expr-score (parse-expr (read (lex "(let ((x (* 2 3))) (+ x 1))"))))))
