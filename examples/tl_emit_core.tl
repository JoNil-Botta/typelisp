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

(define (expr-list-length [xs : ExprList]) : i64
  (match xs
    [(ELNil) 0]
    [(ELCons _ rest) (+ 1 (expr-list-length rest))]))

(define (str-list-length [xs : StrList]) : i64
  (match xs
    [(SLNil) 0]
    [(SLCons _ rest) (+ 1 (str-list-length rest))]))

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

;; arg-reg: SysV AMD64 integer-argument register by index (0->%rdi .. 5->%r9).
;; Slice 1 supports register-passed args only (<= 6); a 7th argument aborts.
(define (arg-reg [i : i64]) : String
  (if (= i 0)
      "%rdi"
      (if (= i 1)
          "%rsi"
          (if (= i 2)
              "%rdx"
              (if (= i 3)
                  "%rcx"
                  (if (= i 4)
                      "%r8"
                      (if (= i 5)
                          "%r9"
                          (begin (panic "emit: more than 6 call arguments") ""))))))))

;; emit-push-args: evaluate every argument left-to-right, pushing each result so
;; the spine is preserved across the next argument's own (possibly clobbering)
;; evaluation. Each `pushq`/`popq` pair is balanced, so %rsp returns to its
;; 16-byte alignment before the `call`.
(define (emit-push-args [env : CEnv] [depth : i64] [lc : (Array i64)] [args : ExprList]) : String
  (match args
    [(ELNil) ""]
    [(ELCons a rest)
     (string-append (emit-expr-in env depth lc a)
       (string-append "    pushq %rax\n"
         (emit-push-args env depth lc rest)))]))

;; emit-pop-args: pop the pushed arguments into their argument registers. The
;; LAST argument is on top of the stack, so popping in REVERSE index order
;; (n-1 down to 0) lands arg0 in %rdi .. argN-1 in reg N-1.
(define (emit-pop-args [i : i64]) : String
  (if (< i 0)
      ""
      (string-append "    popq "
        (string-append (arg-reg i)
          (string-append "\n"
            (emit-pop-args (- i 1)))))))

;; emit-call: SysV direct call. Evaluate args left-to-right onto the stack, pop
;; them into the argument registers (reverse order), `call <name>`, result in
;; %rax. Recursion and mutual recursion fall out free because `<name>` resolves
;; at assembly time.
(define (emit-call [env : CEnv] [depth : i64] [lc : (Array i64)] [name : String] [args : ExprList]) : String
  (let ([n : i64 (expr-list-length args)])
    (string-append (emit-push-args env depth lc args)
      (string-append (emit-pop-args (- n 1))
        (string-append "    call "
          (string-append name "\n"))))))

(define (emit-expr-in [env : CEnv] [depth : i64] [lc : (Array i64)] [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar name) (emit-var env name)]
    [(EBin op a b) (emit-bin env depth lc op a b)]
    [(ELet name value body) (emit-let env depth lc name value body)]
    [(EIf c t e) (emit-if env depth lc c t e)]
    [(ECall name args) (emit-call env depth lc name args)]))

(define (emit-expr [e : Expr]) : String
  (let ([lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (emit-expr-in CNil 0 lc e))))

;; --------------------------------------------------------------------------
;; define + calls (#169): per-function blocks with the SysV calling convention.
;; --------------------------------------------------------------------------

;; bind-params: extend the function's initial CEnv so EVar resolves each
;; parameter through the SAME cenv-lookup/emit-var path as a `let` binding.
;; Parameter i (0-based) lives in stack slot -8*(i+1)(%rbp), the slot its
;; prologue spill writes; subsequent `let` slots start past the last parameter.
(define (bind-params [env : CEnv] [params : StrList] [i : i64]) : CEnv
  (match params
    [(SLNil) env]
    [(SLCons name rest)
     (bind-params (CBind name (slot-offset (+ i 1)) env) rest (+ i 1))]))

;; emit-spill-params: copy the incoming argument registers into the parameter
;; stack slots so the body reads them as ordinary locals. Parameter i moves
;; from `arg-reg i` into slot -8*(i+1)(%rbp).
(define (emit-spill-params [params : StrList] [i : i64]) : String
  (match params
    [(SLNil) ""]
    [(SLCons _ rest)
     (string-append "    movq "
       (string-append (arg-reg i)
         (string-append ", "
           (string-append (emit-slot (slot-offset (+ i 1)))
             (string-append "\n"
               (emit-spill-params rest (+ i 1)))))))]))

;; emit-fn-block: lower one `(IDefFn name params body)` to its own `<name>:`
;; block. Frame holds the parameter slots plus the body's lexical `let` slots,
;; rounded up to 16 so %rsp stays aligned at every nested `call`. The body is
;; emitted at depth = nparams so its first `let` slot sits past the last
;; parameter; params are pre-bound into the CEnv so EVar resolves them.
(define (emit-fn-block [lc : (Array i64)] [name : String] [params : StrList] [body : Expr]) : String
  (let ([nparams : i64 (str-list-length params)])
    (let ([frame : i64 (round-up-16 (* 8 (+ nparams (max-let-depth body))))]
          [env : CEnv (bind-params CNil params 0)])
      (string-append name
        (string-append ":\n"
          (string-append "    push %rbp\n"
            (string-append "    mov %rsp, %rbp\n"
              (string-append (emit-stack-sub frame)
                (string-append (emit-spill-params params 0)
                  (string-append (emit-expr-in env nparams lc body)
                    (string-append (emit-stack-add frame)
                      (string-append "    pop %rbp\n"
                        "    ret\n\n"))))))))))))

;; emit-fn-blocks: lower every define in the program to its block, threading a
;; SHARED label counter so every `.Lelse_`/`.Lend_` across all functions stays
;; unique.
(define (emit-fn-blocks [lc : (Array i64)] [items : ItemList]) : String
  (match items
    [(ILNil) ""]
    [(ILCons item rest)
     (match item
       [(IDefFn name params body)
        (string-append (emit-fn-block lc name params body)
          (emit-fn-blocks lc rest))])]))

;; emit-items: the multi-define program driver. Each `(define (name p..) body)`
;; becomes its own `<name>:` block; the define named `main` is the entry that
;; `_start` calls and whose %rax becomes the process exit code. Recursion and
;; mutual recursion need no special handling: a self/peer `call <name>` resolves
;; against the emitted label at assembly time.
(define (emit-items [items : ItemList]) : String
  (let ([lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (string-append "    .text\n"
        (string-append "    .globl main\n"
          (string-append "    .globl _start\n\n"
            (string-append (emit-fn-blocks lc items)
              (string-append "_start:\n"
                (string-append "    call main\n"
                  (string-append "    movq %rax, %rdi\n"
                    (string-append "    movq $60, %rax\n"
                      "    syscall\n")))))))))))

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
