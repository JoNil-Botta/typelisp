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

;; parse-if (#167): project `(if c t e)` onto `(EIf c t e)`. The argument spine
;; must be exactly three forms (cond, then, else); any other shape is malformed
;; input and aborts via `panic`, matching `parse-let`'s discipline.
(define (parse-if [rest : Sexpr]) : Expr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (EIf (parse-expr c) (parse-expr t) (parse-expr e))]
    [_ (begin (panic "ast: malformed if") (EInt 0))]))

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
                 (if (string-eq op "<")
                     (parse-binary (OpLt) rest)
                     (if (string-eq op "=")
                         (parse-binary (OpEq) rest)
                         (if (string-eq op "<=")
                             (parse-binary (OpLe) rest)
                             (if (string-eq op ">")
                                 (parse-binary (OpGt) rest)
                                 (if (string-eq op ">=")
                                     (parse-binary (OpGe) rest)
                                     (if (string-eq op "!=")
                                         (parse-binary (OpNe) rest)
                                         (if (string-eq op "let")
                                             (parse-let rest)
                                             (if (string-eq op "if")
                                                 (parse-if rest)
                                                 (ECall op (parse-args rest)))))))))))))]
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
    [(OpMul) 30]
    [(OpLt) 40]
    [(OpEq) 50]
    [(OpLe) 60]
    [(OpGt) 70]
    [(OpGe) 80]
    [(OpNe) 90]))

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
    [(EIf c t e) (+ (expr-score c) (+ (expr-score t) (expr-score e)))]
    [(ECall name args) (+ (string-length name) (expr-list-score args))]))

(define (item-score [i : Item]) : i64
  (match i
    [(IDefFn name params body)
     (+ (string-length name) (+ (str-list-count params) (expr-score body)))]))

(define (main) : i64
  (+ (+ (expr-score (parse-expr (read (lex "(+ 1 (* 2 3))"))))
        (item-score (parse-item (read (lex "(define (main) (+ 1 (* 2 3)))")))))
     (+ (expr-score (parse-expr (read (lex "(let ((x (* 2 3))) (+ x 1))"))))
        (+ (expr-score (parse-expr (read (lex "(if (< 1 2) (= 3 3) 0)"))))
           (+ (expr-score (parse-expr (read (lex "(<= 3 3)"))))
              (+ (expr-score (parse-expr (read (lex "(> 5 2)"))))
                 (+ (expr-score (parse-expr (read (lex "(>= 5 5)"))))
                    (expr-score (parse-expr (read (lex "(!= 7 8)")))))))))))
