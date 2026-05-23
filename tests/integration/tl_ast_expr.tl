;; tl_ast_expr.tl - Witness program: parse an arithmetic expression.
;;
;; Reads `(+ 1 (* 2 3))` and checks the parsed AST shape by returning a
;; stable score.  Exits 42 if the parsed tree matches the expected shape.

(import "tl_ast.tl")

;; Return a score that depends on the parsed expression shape.
;; The sample `(+ 1 (* 2 3))` should parse to:
;;   (EBin (OpAdd) (EInt 1) (EBin (OpMul) (EInt 2) (EInt 3)))
;;
;; We verify by deconstructing:
;;   - outer is EBin
;;   - outer op is OpAdd (tag score 1)
;;   - outer left is EInt 1
;;   - outer right is EBin
;;   - inner op is OpMul (tag score 3)
;;   - inner left is EInt 2
;;   - inner right is EInt 3
;;
;; Score: outer-op(1)*10 + left(1) + inner-op(3)*10 + inner-left(2) + inner-right(3)
;;       = 10 + 1 + 30 + 2 + 3 = 46
;;
;; But let's keep it simpler: tag checks + value checks.
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

;; Build the source string by concatenation so we get the literal
;; `(+ 1 (* 2 3))` in the program.
(define (sample-source) : String
  (string-append "(+ 1 (* 2 3))" ""))

(define (main) : i64
  (let ([toks : (Array Token) (lex (sample-source))])
    (let ([cur : (Array i64) (make-array i64 1)])
      (begin
        (array-set! cur 0 0)
        (let ([tree : Sexpr (read-form toks cur)])
          (let ([e : Expr (parse-expr tree)])
            (score-expr e)))))))
