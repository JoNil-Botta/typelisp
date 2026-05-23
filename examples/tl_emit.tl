;; tl_emit.tl - Milestone 1 self-hosting code emitter.
;;
;; This is the backend half of the first self-hosted compiler slice (#155). It
;; lowers a tiny arithmetic Expr AST to x86_64 text using a stack discipline:
;; every expression leaves its result in %rax; a binary expression pushes the
;; left result, emits the right, moves it to %rcx, restores the left result, and
;; emits the operator instruction.

(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul))

(defenum Expr
  (EInt i64)
  (EBin BinOp Expr Expr))

(define (emit-int [n : i64]) : String
  (string-append "    movq $" (string-append (int->string n) ", %rax\n")))

(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]))

(define (emit-bin [op : BinOp] [a : Expr] [b : Expr]) : String
  (string-append (emit-expr a)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr b)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-expr [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EBin op a b) (emit-bin op a b)]))

(define (sample) : Expr
  (EBin (OpAdd) (EInt 1) (EBin (OpMul) (EInt 2) (EInt 3))))

(define (main) : unit
  (print-string (emit-expr (sample))))
