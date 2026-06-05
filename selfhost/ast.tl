;; ast.tl - Sexpr -> compiler AST parser for the M1 self-hosting slice (#154).
(import "../stdlib/io.tl")

(import "ast_types.tl")

(import "read.tl")

(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SCons a _) (box-get a)]
    [_
      (begin
        (panic "ast: expected non-empty list")
        SNil)]))

(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SCons _ d) (box-get d)]
    [_
      (begin
        (panic "ast: expected list tail")
        SNil)]))

(define (sexpr-expect-nil [s : Sexpr]) : unit
  (match s
    [(SNil) (print-string "")]
    [_ (panic "ast: expected end of list")]))

(define (parse-binary [op : BinOp] [rest : Sexpr]) : Expr
  (let
    [a : Sexpr (sexpr-head rest)]
    [after-a : Sexpr (sexpr-tail rest)]
    [b : Sexpr (sexpr-head after-a)]
    [after-b : Sexpr (sexpr-tail after-a)]
    (begin
      (sexpr-expect-nil after-b)
      (EBin op (box (parse-expr a)) (box (parse-expr b))))))

(define (parse-not [rest : Sexpr]) : Expr
  (match rest
    [(SCons arg end)
      (match (box-get end)
        [(SNil) (ENot (box (parse-expr (box-get arg))))]
        [_
          (begin
            (panic "ast: malformed not")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed not")
        (EInt 0))]))

(define (parse-let-bindings [bindings : Sexpr] [body : Expr]) : Expr
  (match bindings
    [(SNil) body]
    [(SCons binding rest)
      (match (box-get binding)
        [(SCons name-node value-tail)
          (match (box-get name-node)
            [(SSym name)
              (match (box-get value-tail)
                [(SCons value end)
                  (match (box-get end)
                    [(SNil)
                      (ELet
                        name
                        (box (parse-expr (box-get value)))
                        (box (parse-let-bindings (box-get rest) body)))]
                    [_
                      (begin
                        (panic "ast: malformed let binding")
                        (EInt 0))])]
                [_
                  (begin
                    (panic "ast: malformed let binding")
                    (EInt 0))])]
            [_
              (begin
                (panic "ast: malformed let binding")
                (EInt 0))])]
        [_
          (begin
            (panic "ast: malformed let binding")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed let binding")
        (EInt 0))]))

(define (parse-let [rest : Sexpr]) : Expr
  (match rest
    [(SCons bindings body-tail)
      (match (box-get body-tail)
        [(SCons body end)
          (match (box-get end)
            [(SNil)
              (parse-let-bindings
                (box-get bindings)
                (parse-expr (box-get body)))]
            [_
              (begin
                (panic "ast: malformed let")
                (EInt 0))])]
        [_
          (begin
            (panic "ast: malformed let")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed let")
        (EInt 0))]))

(define (parse-set [rest : Sexpr]) : Expr
  (match rest
    [(SCons name-node value-tail)
      (match (box-get name-node)
        [(SSym name)
          (match (box-get value-tail)
            [(SCons value end)
              (match (box-get end)
                [(SNil) (ESet name (box (parse-expr (box-get value))))]
                [_
                  (begin
                    (panic "ast: malformed set!")
                    (EInt 0))])]
            [_
              (begin
                (panic "ast: malformed set!")
                (EInt 0))])]
        [_
          (begin
            (panic "ast: malformed set!")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed set!")
        (EInt 0))]))

;; parse-if (#167): project `(if c t e)` onto `(EIf c t e)`. The argument spine
;; must be exactly three forms (cond, then, else); any other shape is malformed
;; input and aborts via `panic`, matching `parse-let`'s discipline.
(define (parse-if [rest : Sexpr]) : Expr
  (match rest
    [(SCons c then-tail)
      (match (box-get then-tail)
        [(SCons t else-tail)
          (match (box-get else-tail)
            [(SCons e end)
              (match (box-get end)
                [(SNil)
                  (EIf
                    (box (parse-expr (box-get c)))
                    (box (parse-expr (box-get t)))
                    (box (parse-expr (box-get e))))]
                [_
                  (begin
                    (panic "ast: malformed if")
                    (EInt 0))])]
            [_
              (begin
                (panic "ast: malformed if")
                (EInt 0))])]
        [_
          (begin
            (panic "ast: malformed if")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed if")
        (EInt 0))]))

(define (parse-while [rest : Sexpr]) : Expr
  (match rest
    [(SCons c body-tail)
      (match (box-get body-tail)
        [(SCons body end)
          (match (box-get end)
            [(SNil)
              (EWhile
                (box (parse-expr (box-get c)))
                (box (parse-expr (box-get body))))]
            [_
              (begin
                (panic "ast: malformed while")
                (EInt 0))])]
        [_
          (begin
            (panic "ast: malformed while")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed while")
        (EInt 0))]))

(define (parse-print [rest : Sexpr]) : Expr
  (match rest
    [(SCons arg end)
      (match (box-get end)
        [(SNil) (EPrint (box (parse-expr (box-get arg))))]
        [_
          (begin
            (panic "ast: malformed print")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed print")
        (EInt 0))]))

(define (parse-begin [rest : Sexpr]) : Expr
  (match rest
    [(SNil)
      (begin
        (panic "ast: empty begin")
        (EInt 0))]
    [(SCons _ _) (EBegin (box (parse-args rest)))]
    [_
      (begin
        (panic "ast: malformed begin")
        (EInt 0))]))

(define (parse-args [s : Sexpr]) : ExprList
  (match s
    [(SNil) ELNil]
    [(SCons a d)
      (ELCons (parse-expr (box-get a)) (box (parse-args (box-get d))))]
    [_
      (begin
        (panic "ast: malformed argument list")
        ELNil)]))

(define (parse-expr [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SStr s) (EStr s)]
    [(SFloat _)
      (begin
        (panic "ast: unsupported float literal")
        (EInt 0))]
    [(SChar _)
      (begin
        (panic "ast: unsupported char literal")
        (EInt 0))]
    [(SCons head rest)
      (match (box-get head)
        [(SSym op)
          (cond
            [(string-eq op "+") (parse-binary (OpAdd) (box-get rest))]
            [(string-eq op "-") (parse-binary (OpSub) (box-get rest))]
            [(string-eq op "*") (parse-binary (OpMul) (box-get rest))]
            [(string-eq op "<") (parse-binary (OpLt) (box-get rest))]
            [(string-eq op "=") (parse-binary (OpEq) (box-get rest))]
            [(string-eq op "<=") (parse-binary (OpLe) (box-get rest))]
            [(string-eq op ">") (parse-binary (OpGt) (box-get rest))]
            [(string-eq op ">=") (parse-binary (OpGe) (box-get rest))]
            [(string-eq op "!=") (parse-binary (OpNe) (box-get rest))]
            [(string-eq op "and") (parse-binary (OpAnd) (box-get rest))]
            [(string-eq op "or") (parse-binary (OpOr) (box-get rest))]
            [(string-eq op "not") (parse-not (box-get rest))]
            [(string-eq op "let") (parse-let (box-get rest))]
            [(string-eq op "if") (parse-if (box-get rest))]
            [(string-eq op "while") (parse-while (box-get rest))]
            [(string-eq op "print") (parse-print (box-get rest))]
            [(string-eq op "set!") (parse-set (box-get rest))]
            [(string-eq op "begin") (parse-begin (box-get rest))]
            [else (ECall op (box (parse-args (box-get rest))))])]
        [_
          (begin
            (panic "ast: malformed expression")
            (EInt 0))])]
    [_
      (begin
        (panic "ast: malformed expression")
        (EInt 0))]))

(define (parse-params [s : Sexpr]) : StrList
  (match s
    [(SNil) SLNil]
    [(SCons name-node rest)
      (match (box-get name-node)
        [(SSym name) (SLCons name (box (parse-params (box-get rest))))]
        [_
          (begin
            (panic "ast: malformed parameter list")
            SLNil)])]
    [_
      (begin
        (panic "ast: malformed parameter list")
        SLNil)]))

(define (parse-item [s : Sexpr]) : Item
  (match s
    [(SCons head-node rest)
      (match (box-get head-node)
        [(SSym head)
          (if (string-eq head "define")
            (let
              [rest : Sexpr (box-get rest)]
              [header : Sexpr (sexpr-head rest)]
              [after-header : Sexpr (sexpr-tail rest)]
              [body : Sexpr (sexpr-head after-header)]
              [after-body : Sexpr (sexpr-tail after-header)]
              (begin
                (sexpr-expect-nil after-body)
                (match header
                  [(SCons name-node params)
                    (match (box-get name-node)
                      [(SSym name)
                        (IDefFn
                          name
                          (parse-params (box-get params))
                          (parse-expr body))]
                      [_
                        (begin
                          (panic "ast: malformed define header")
                          (IDefFn "" SLNil (EInt 0)))])]
                  [_
                    (begin
                      (panic "ast: malformed define header")
                      (IDefFn "" SLNil (EInt 0)))])))
            (begin
              (panic "ast: expected define")
              (IDefFn "" SLNil (EInt 0))))]
        [_
          (begin
            (panic "ast: malformed item")
            (IDefFn "" SLNil (EInt 0)))])]
    [_
      (begin
        (panic "ast: malformed item")
        (IDefFn "" SLNil (EInt 0)))]))

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
    [(OpNe) 90]
    [(OpAnd) 100]
    [(OpOr) 110]))

(define (expr-list-score [xs : ExprList]) : i64
  (match xs
    [(ELNil) 0]
    [(ELCons e rest) (+ (expr-score e) (expr-list-score (box-get rest)))]))

(define (str-list-count [xs : StrList]) : i64
  (match xs
    [(SLNil) 0]
    [(SLCons _ rest) (+ 1 (str-list-count (box-get rest)))]))

(define (expr-score [e : Expr]) : i64
  (match e
    [(EInt n) n]
    [(EVar name) (string-length name)]
    [(EBin op a b)
      (+ (op-score op) (+ (expr-score (box-get a)) (expr-score (box-get b))))]
    [(ENot e) (+ 120 (expr-score (box-get e)))]
    [(ELet name value body)
      (+
        (string-length name)
        (+ (expr-score (box-get value)) (expr-score (box-get body))))]
    [(EIf c t e)
      (+
        (expr-score (box-get c))
        (+ (expr-score (box-get t)) (expr-score (box-get e))))]
    [(EWhile c body)
      (+ 400 (+ (expr-score (box-get c)) (expr-score (box-get body))))]
    [(ECall name args)
      (+ (string-length name) (expr-list-score (box-get args)))]
    [(EStr s) (string-length s)]
    [(EPrint e) (+ 100 (expr-score (box-get e)))]
    [(ESet name value)
      (+ 300 (+ (string-length name) (expr-score (box-get value))))]
    [(EBegin body) (+ 200 (expr-list-score (box-get body)))]))

(define (item-score [i : Item]) : i64
  (match i
    [(IDefFn name params body)
      (+ (string-length name) (+ (str-list-count params) (expr-score body)))]))

(define (main) : i64
  (+
    (+
      (expr-score (parse-expr (read (lex "(+ 1 (* 2 3))"))))
      (item-score (parse-item (read (lex "(define (main) (+ 1 (* 2 3)))")))))
    (+
      (expr-score (parse-expr (read (lex "(let ((x (* 2 3))) (+ x 1))"))))
      (+
        (expr-score (parse-expr (read (lex "(if (< 1 2) (= 3 3) 0)"))))
        (+
          (expr-score (parse-expr (read (lex "(<= 3 3)"))))
          (+
            (expr-score (parse-expr (read (lex "(> 5 2)"))))
            (+
              (expr-score (parse-expr (read (lex "(>= 5 5)"))))
              (+
                (expr-score (parse-expr (read (lex "(!= 7 8)"))))
                (+
                  (expr-score (parse-expr (read (lex "\"hi\""))))
                  (expr-score (parse-expr (read (lex "(print \"ok\")")))))))))))))