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

(define (expr-list-count [xs : ExprList]) : i64
  (match xs
    [(ELNil) 0]
    [(ELCons _ rest) (+ 1 (expr-list-count rest))]))

(define (str-list-count [xs : StrList]) : i64
  (match xs
    [(SLNil) 0]
    [(SLCons _ rest) (+ 1 (str-list-count rest))]))

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

(define (checked-max-six [n : i64] [message : String]) : i64
  (if (< 6 n)
      (begin (panic message) 0)
      n))

(define (arg-reg [idx : i64]) : String
  (if (= idx 0)
      "%rdi"
      (if (= idx 1)
          "%rsi"
          (if (= idx 2)
              "%rdx"
              (if (= idx 3)
                  "%rcx"
                  (if (= idx 4)
                      "%r8"
                      (if (= idx 5)
                          "%r9"
                          (begin
                            (panic "emit: arg register index out of range")
                            "%rdi"))))))))

(define (bind-params [params : StrList] [slot : i64] [env : CEnv]) : CEnv
  (match params
    [(SLNil) env]
    [(SLCons name rest)
     (bind-params rest (+ slot 1) (CBind name (slot-offset slot) env))]))

(define (emit-param-spills [params : StrList] [idx : i64]) : String
  (match params
    [(SLNil) ""]
    [(SLCons _ rest)
     (string-append "    movq "
       (string-append (arg-reg idx)
         (string-append ", "
           (string-append (emit-slot (slot-offset (+ idx 1)))
             (string-append "\n" (emit-param-spills rest (+ idx 1)))))))]))

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

(define (emit-call-arg-pushes [env : CEnv] [depth : i64] [lc : (Array i64)] [args : ExprList]) : String
  (match args
    [(ELNil) ""]
    [(ELCons arg rest)
     (string-append (emit-expr-in env depth lc arg)
       (string-append "    pushq %rax\n"
         (emit-call-arg-pushes env depth lc rest)))]))

(define (emit-call-arg-pops [argc : i64]) : String
  (if (= argc 0)
      ""
      (let ([idx : i64 (- argc 1)])
        (string-append "    popq "
          (string-append (arg-reg idx)
            (string-append "\n" (emit-call-arg-pops idx)))))))

(define (emit-call [env : CEnv] [depth : i64] [lc : (Array i64)] [name : String] [args : ExprList]) : String
  (let ([argc : i64 (checked-max-six (expr-list-count args) "emit: too many call args")])
    (string-append (emit-call-arg-pushes env depth lc args)
      (string-append (emit-call-arg-pops argc)
        (string-append "    call " (string-append name "\n"))))))

(define (emit-expr-in [env : CEnv] [depth : i64] [lc : (Array i64)] [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar name) (emit-var env name)]
    [(EBin op a b) (emit-bin env depth lc op a b)]
    [(ELet name value body) (emit-let env depth lc name value body)]
    [(EIf c t e) (emit-if env depth lc c t e)]
    [(ECall name args) (emit-call env depth lc name args)]))

(define (function-frame-size [params : StrList] [body : Expr]) : i64
  (round-up-16 (* 8 (+ (str-list-count params) (max-let-depth body)))))

(define (emit-def [lc : (Array i64)] [item : Item]) : String
  (match item
    [(IDefFn name params body)
     (let ([nparams : i64 (checked-max-six (str-list-count params) "emit: too many params")])
       (let ([frame : i64 (function-frame-size params body)])
         (string-append name
           (string-append ":\n"
             (string-append "    push %rbp\n"
               (string-append "    mov %rsp, %rbp\n"
                 (string-append (emit-stack-sub frame)
                   (string-append (emit-param-spills params 0)
                     (string-append (emit-expr-in (bind-params params 1 CNil) nparams lc body)
                       (string-append "    mov %rbp, %rsp\n"
                         (string-append "    pop %rbp\n"
                           "    ret\n\n")))))))))))]))

(define (emit-defs [lc : (Array i64)] [items : ItemList]) : String
  (match items
    [(ILNil) ""]
    [(ILCons item rest) (string-append (emit-def lc item) (emit-defs lc rest))]))

(define (emit-expr [e : Expr]) : String
  (let ([lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (emit-expr-in CNil 0 lc e))))

(define (emit-entry [frame : i64] [body : String]) : String
  (string-append "main:\n"
    (string-append "    push %rbp\n"
      (string-append "    mov %rsp, %rbp\n"
        (string-append (emit-stack-sub frame)
          (string-append body
            (string-append (emit-stack-add frame)
              (string-append "    pop %rbp\n"
                (string-append "    ret\n\n"
                  (string-append "_start:\n"
                    (string-append "    call main\n"
                      (string-append "    movq %rax, %rdi\n"
                        (string-append "    movq $60, %rax\n"
                          "    syscall\n")))))))))))))

;; emit-program-with-defs: emit user `define` blocks before the entry wrapper.
;; `emit-program` stays as the no-define compatibility wrapper.
(define (emit-program-with-defs [defs : ItemList] [e : Expr]) : String
  (let ([frame : i64 (frame-size e)]
        [lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (string-append "    .text\n"
        (string-append "    .globl main\n"
          (string-append "    .globl _start\n\n"
            (string-append (emit-defs lc defs)
              (emit-entry frame (emit-expr-in CNil 0 lc e)))))))))

(define (emit-program [e : Expr]) : String
  (emit-program-with-defs ILNil e))
