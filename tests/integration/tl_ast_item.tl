;; tl_ast_item.tl - Witness program: parse a top-level function definition.
;;
;; Reads `(define (main) (+ 1 (* 2 3)))` and checks the parsed Item shape.
;; Verifies name is "main", param count is 0, and body score matches.
;; Exits with a packed score: (param-count * 100) + body-score.

(import "tl_ast.tl")

;; Score an expression (same logic as tl_ast_expr.tl).
(define (score-expr [e : Expr]) : i64
  (match e
    [(EBin op l r)
     (+ (+ (match op [(OpAdd) 1] [(OpSub) 2] [(OpMul) 3])
           (match l [(EInt n) n] [_ 0]))
        (match r
          [(EBin op2 l2 r2)
           (+ (+ (match op2 [(OpAdd) 1] [(OpSub) 2] [(OpMul) 3])
                 (match l2 [(EInt n) n] [_ 0]))
              (match r2 [(EInt n) n] [_ 0]))]
          [_ 0]))]
    [_ 0]))

;; Count the length of a StrList.
(define (str-list-len [sl : StrList]) : i64
  (match sl
    [(SLNil) 0]
    [(SLCons _ t) (+ 1 (str-list-len t))]))

;; Build the source string.
(define (sample-source) : String
  (string-append "(define (main) (+ 1 (* 2 3)))" ""))

(define (main) : i64
  (let ([toks : (Array Token) (lex (sample-source))])
    (let ([cur : (Array i64) (make-array i64 1)])
      (begin
        (array-set! cur 0 0)
        (let ([tree : Sexpr (read-form toks cur)])
          (let ([item : Item (parse-item tree)])
            (match item
              [(IDefFn name params body)
               (if (string-eq name "main")
                   (let ([pc : i64 (str-list-len params)]
                         [bs : i64 (score-expr body)])
                     (+ (* pc 100) bs))
                   0)])))))))
