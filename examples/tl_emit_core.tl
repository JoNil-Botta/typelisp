;; tl_emit_core.tl - Main-less M1 assembly emitter shared by demos/tests (#163).

(import "tl_ast_types.tl")

(defenum CEnv
  (CNil)
  (CBind String i64 CEnv))

(define (max-i64 [a : i64] [b : i64]) : i64
  (if (< a b) b a))

(define (cenv-lookup [env : CEnv] [name : String]) : i64
  (match env
    [(CNil) (begin (panic "emit: unbound variable") 0)]
    [(CBind bound off rest)
     (if (string-eq bound name)
         off
         (cenv-lookup rest name))]))

(define (slot-offset [depth : i64]) : i64
  (- 0 (* 8 depth)))

(define (emit-slot [off : i64]) : String
  (string-append (int->string off) "(%rbp)"))

(define (emit-stack-sub [bytes : i64]) : String
  (if (= bytes 0)
      ""
      (string-append "    sub $" (string-append (int->string bytes) ", %rsp\n"))))

(define (emit-stack-add [bytes : i64]) : String
  (if (= bytes 0)
      ""
      (string-append "    add $" (string-append (int->string bytes) ", %rsp\n"))))

(define (round-up-16 [n : i64]) : i64
  (if (= n 0)
      0
      (* (/ (+ n 15) 16) 16)))

(define (expr-list-max-let-depth [xs : ExprList]) : i64
  (match xs
    [(ELNil) 0]
    [(ELCons e rest) (max-i64 (max-let-depth e) (expr-list-max-let-depth rest))]))

(define (max-let-depth [e : Expr]) : i64
  (match e
    [(EInt _) 0]
    [(EVar _) 0]
    [(EBin _ a b) (max-i64 (max-let-depth a) (max-let-depth b))]
    [(ELet _ value body)
     (max-i64 (max-let-depth value) (+ 1 (max-let-depth body)))]
    [(EIf c t e)
     (max-i64 (max-let-depth c) (max-i64 (max-let-depth t) (max-let-depth e)))]
    [(ECall _ args) (expr-list-max-let-depth args)]))

(define (frame-size [e : Expr]) : i64
  (round-up-16 (* 8 (max-let-depth e))))

(define (fresh-label [lc : (Array i64)] [prefix : String]) : String
  (let ([id : i64 (array-ref lc 0)])
    (begin
      (array-set! lc 0 (+ id 1))
      (string-append prefix (int->string id)))))

(define (emit-int [n : i64]) : String
  (string-append "    movq $" (string-append (int->string n) ", %rax\n")))

(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]
    [(OpLt) "    cmpq %rcx, %rax\n    setl %al\n    movzbq %al, %rax\n"]
    [(OpEq) "    cmpq %rcx, %rax\n    sete %al\n    movzbq %al, %rax\n"]))

(define (emit-var [env : CEnv] [name : String]) : String
  (string-append "    movq "
    (string-append (emit-slot (cenv-lookup env name)) ", %rax\n")))

(define (emit-bin [env : CEnv] [depth : i64] [lc : (Array i64)] [op : BinOp] [a : Expr] [b : Expr]) : String
  (string-append (emit-expr-in env depth lc a)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr-in env depth lc b)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-let [env : CEnv] [depth : i64] [lc : (Array i64)] [name : String] [value : Expr] [body : Expr]) : String
  (let ([next-depth : i64 (+ depth 1)])
    (let ([off : i64 (slot-offset next-depth)])
      (string-append (emit-expr-in env depth lc value)
        (string-append "    movq %rax, "
          (string-append (emit-slot off)
            (string-append "\n"
              (emit-expr-in (CBind name off env) next-depth lc body))))))))

(define (emit-if [env : CEnv] [depth : i64] [lc : (Array i64)] [c : Expr] [t : Expr] [e : Expr]) : String
  (let ([lelse : String (fresh-label lc ".Lelse_")]
        [lend : String (fresh-label lc ".Lend_")])
    (string-append (emit-expr-in env depth lc c)
      (string-append "    cmpq $0, %rax\n"
        (string-append "    je "
          (string-append lelse
            (string-append "\n"
              (string-append (emit-expr-in env depth lc t)
                (string-append "    jmp "
                  (string-append lend
                    (string-append "\n"
                      (string-append lelse
                        (string-append ":\n"
                          (string-append (emit-expr-in env depth lc e)
                            (string-append lend ":\n")))))))))))))))

(define (emit-expr-in [env : CEnv] [depth : i64] [lc : (Array i64)] [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar name) (emit-var env name)]
    [(EBin op a b) (emit-bin env depth lc op a b)]
    [(ELet name value body) (emit-let env depth lc name value body)]
    [(EIf c t e) (emit-if env depth lc c t e)]
    [(ECall _ _) (begin (panic "emit: calls are not in M1 arithmetic") "")]))

(define (emit-expr [e : Expr]) : String
  (let ([lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (emit-expr-in CNil 0 lc e))))

;; emit-program: wrap the body asm in the complete backend-shaped `.s` skeleton.
;; It reserves one aligned frame region for all lexical let slots.
(define (emit-program [e : Expr]) : String
  (let ([frame : i64 (frame-size e)]
        [lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (string-append "    .text\n"
        (string-append "    .globl main\n"
          (string-append "    .globl _start\n\n"
            (string-append "main:\n"
              (string-append "    push %rbp\n"
                (string-append "    mov %rsp, %rbp\n"
                  (string-append (emit-stack-sub frame)
                    (string-append (emit-expr-in CNil 0 lc e)
                      (string-append (emit-stack-add frame)
                        (string-append "    pop %rbp\n"
                          (string-append "    ret\n\n"
                            (string-append "_start:\n"
                              (string-append "    call main\n"
                                (string-append "    movq %rax, %rdi\n"
                                  (string-append "    movq $60, %rax\n"
                                    "    syscall\n"))))))))))))))))))
