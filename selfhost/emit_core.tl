;; emit_core.tl - Main-less M1 assembly emitter shared by demos/tests (#163).

(import "ast_types.tl")
(import "sym_i64_env.tl")

(define (max-i64 [a : i64] [b : i64]) : i64
  (if (< a b) b a))

(define (cenv-lookup [env : SymI64Env] [name : String]) : i64
  (match (sym-i64-lookup env name)
    [(SomeI64 off) off]
    [(NoneI64) (begin (panic "emit: unbound variable") 0)]))

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

(define (str-list-append-one [xs : StrList] [s : String]) : StrList
  (match xs
    [(SLNil) (SLCons s SLNil)]
    [(SLCons head rest) (SLCons head (str-list-append-one rest s))]))

(define (expr-list-collect-strings [xs : ExprList] [acc : StrList]) : StrList
  (match xs
    [(ELNil) acc]
    [(ELCons e rest) (expr-list-collect-strings rest (collect-strings e acc))]))

(define (collect-strings [e : Expr] [acc : StrList]) : StrList
  (match e
    [(EInt _) acc]
    [(EVar _) acc]
    [(EBin _ a b) (collect-strings b (collect-strings a acc))]
    [(ELet _ value body) (collect-strings body (collect-strings value acc))]
    [(EIf c t e) (collect-strings e (collect-strings t (collect-strings c acc)))]
    [(ECall _ args) (expr-list-collect-strings args acc)]
    [(EStr s) (str-list-append-one acc s)]
    [(EPrint e) (collect-strings e acc)]
    [(EBegin exprs) (expr-list-collect-strings exprs acc)]))

(define (collect-item-strings [item : Item] [acc : StrList]) : StrList
  (match item
    [(IDefFn _ _ body) (collect-strings body acc)]))

(define (collect-items-strings [items : ItemList] [acc : StrList]) : StrList
  (match items
    [(ILNil) acc]
    [(ILCons item rest) (collect-items-strings rest (collect-item-strings item acc))]))

(define (string-index-in [needle : String] [xs : StrList] [idx : i64]) : i64
  (match xs
    [(SLNil) (begin (panic "emit: missing string literal") 0)]
    [(SLCons s rest)
     (if (string-eq needle s)
         idx
         (string-index-in needle rest (+ idx 1)))]))

(define (string-index [needle : String] [strings : StrList]) : i64
  (string-index-in needle strings 0))

(define (char-code [c : char]) : i64
  (cast c : i64))

(define (octal-digit [n : i64]) : String
  (if (= n 0)
      "0"
      (if (= n 1)
          "1"
          (if (= n 2)
              "2"
              (if (= n 3)
                  "3"
                  (if (= n 4)
                      "4"
                      (if (= n 5)
                          "5"
                          (if (= n 6)
                              "6"
                              "7"))))))))

(define (octal-escape [n : i64]) : String
  (string-append "\\"
    (string-append (octal-digit (/ n 64))
      (string-append (octal-digit (% (/ n 8) 8))
        (octal-digit (% n 8))))))

(define (escape-string-byte [text : String] [idx : i64] [k : i64]) : String
  (if (= k 34)
      "\\\""
      (if (= k 92)
          "\\\\"
          (if (= k 10)
              "\\n"
              (if (= k 9)
                  "\\t"
                  (if (= k 13)
                      "\\r"
                      (if (and (>= k 32) (<= k 126))
                          (substring text idx 1)
                          (octal-escape k))))))))

(define (escape-string [text : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length text)]
        [out : String ""])
    (begin
      (while (< i n)
        (let ([k : i64 (char-code (string-ref text i))])
          (begin
            (set! out (string-append out (escape-string-byte text i k)))
            (set! i (+ i 1)))))
      out)))

(define (quoted-gas-string [text : String]) : String
  (string-append "\"" (string-append (escape-string text) "\"")))

(define (string-label [idx : i64]) : String
  (string-append ".Lstr_" (int->string idx)))

(define (emit-rodata-entries [strings : StrList] [idx : i64]) : String
  (match strings
    [(SLNil) ""]
    [(SLCons s rest)
     (string-append (string-label idx)
       (string-append ":\n    .string "
         (string-append (quoted-gas-string s)
           (string-append "\n" (emit-rodata-entries rest (+ idx 1))))))]))

(define (emit-rodata [strings : StrList]) : String
  (match strings
    [(SLNil) ""]
    [_ (string-append "    .section .rodata\n"
         (string-append (emit-rodata-entries strings 0) "\n"))]))

(define (max-let-depth [e : Expr]) : i64
  (match e
    [(EInt _) 0]
    [(EVar _) 0]
    [(EBin _ a b) (max-i64 (max-let-depth a) (max-let-depth b))]
    [(ELet _ value body)
     (max-i64 (max-let-depth value) (+ 1 (max-let-depth body)))]
    [(EIf c t e)
     (max-i64 (max-let-depth c) (max-i64 (max-let-depth t) (max-let-depth e)))]
    [(ECall _ args) (expr-list-max-let-depth args)]
    [(EStr _) 0]
    [(EPrint e) (max-let-depth e)]
    [(EBegin exprs) (expr-list-max-let-depth exprs)]))

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

(define (bind-params [params : StrList] [slot : i64] [env : SymI64Env]) : SymI64Env
  (match params
    [(SLNil) env]
    [(SLCons name rest)
     (bind-params rest (+ slot 1) (sym-i64-bind env name (slot-offset slot)))]))

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
    [(OpEq) "    cmpq %rcx, %rax\n    sete %al\n    movzbq %al, %rax\n"]
    [(OpLe) "    cmpq %rcx, %rax\n    setle %al\n    movzbq %al, %rax\n"]
    [(OpGt) "    cmpq %rcx, %rax\n    setg %al\n    movzbq %al, %rax\n"]
    [(OpGe) "    cmpq %rcx, %rax\n    setge %al\n    movzbq %al, %rax\n"]
    [(OpNe) "    cmpq %rcx, %rax\n    setne %al\n    movzbq %al, %rax\n"]))

(define (emit-var [env : SymI64Env] [name : String]) : String
  (string-append "    movq "
    (string-append (emit-slot (cenv-lookup env name)) ", %rax\n")))

(define (emit-bin [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [op : BinOp] [a : Expr] [b : Expr]) : String
  (string-append (emit-expr-in strings env depth lc a)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr-in strings env depth lc b)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-let [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [name : String] [value : Expr] [body : Expr]) : String
  (let ([next-depth : i64 (+ depth 1)])
    (let ([off : i64 (slot-offset next-depth)])
      (string-append (emit-expr-in strings env depth lc value)
        (string-append "    movq %rax, "
          (string-append (emit-slot off)
            (string-append "\n"
              (emit-expr-in strings (sym-i64-bind env name off) next-depth lc body))))))))

(define (emit-if [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [c : Expr] [t : Expr] [e : Expr]) : String
  (let ([lelse : String (fresh-label lc ".Lelse_")]
        [lend : String (fresh-label lc ".Lend_")])
    (string-append (emit-expr-in strings env depth lc c)
      (string-append "    cmpq $0, %rax\n"
        (string-append "    je "
          (string-append lelse
            (string-append "\n"
              (string-append (emit-expr-in strings env depth lc t)
                (string-append "    jmp "
                  (string-append lend
                    (string-append "\n"
                      (string-append lelse
                        (string-append ":\n"
                          (string-append (emit-expr-in strings env depth lc e)
                            (string-append lend ":\n")))))))))))))))

(define (emit-call-arg-pushes [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [args : ExprList]) : String
  (match args
    [(ELNil) ""]
    [(ELCons arg rest)
     (string-append (emit-expr-in strings env depth lc arg)
       (string-append "    pushq %rax\n"
         (emit-call-arg-pushes strings env depth lc rest)))]))

(define (emit-call-arg-pops [argc : i64]) : String
  (if (= argc 0)
      ""
      (let ([idx : i64 (- argc 1)])
        (string-append "    popq "
          (string-append (arg-reg idx)
            (string-append "\n" (emit-call-arg-pops idx)))))))

(define (emit-call [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [name : String] [args : ExprList]) : String
  (let ([argc : i64 (checked-max-six (expr-list-count args) "emit: too many call args")])
    (string-append (emit-call-arg-pushes strings env depth lc args)
      (string-append (emit-call-arg-pops argc)
        (string-append "    call " (string-append name "\n"))))))

(define (emit-str [strings : StrList] [s : String]) : String
  (string-append "    leaq "
    (string-append (string-label (string-index s strings)) "(%rip), %rax\n")))

(define (emit-print [strings : StrList] [arg : Expr]) : String
  (match arg
    [(EStr s)
     (let ([label : String (string-label (string-index s strings))])
       (string-append "    leaq "
         (string-append label
           (string-append "(%rip), %rsi\n"
             (string-append "    movq $"
               (string-append (int->string (string-length s))
                 (string-append ", %rdx\n"
                   (string-append "    movq $1, %rdi\n"
                     (string-append "    movq $1, %rax\n"
                        (string-append "    syscall\n"
                          "    movq $0, %rax\n"))))))))))]
    [_ (begin (panic "emit: print expects string literal") "")]))

(define (emit-begin [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [exprs : ExprList]) : String
  (match exprs
    [(ELNil) (begin
               (panic "emit: empty begin")
               "")]
    [(ELCons e (ELNil)) (emit-expr-in strings env depth lc e)]
    [(ELCons e rest)
     (string-append (emit-expr-in strings env depth lc e)
       (emit-begin strings env depth lc rest))]))

(define (emit-expr-in [strings : StrList] [env : SymI64Env] [depth : i64] [lc : (Array i64)] [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar name) (emit-var env name)]
    [(EBin op a b) (emit-bin strings env depth lc op a b)]
    [(ELet name value body) (emit-let strings env depth lc name value body)]
    [(EIf c t e) (emit-if strings env depth lc c t e)]
    [(ECall name args) (emit-call strings env depth lc name args)]
    [(EStr s) (emit-str strings s)]
    [(EPrint arg) (emit-print strings arg)]
    [(EBegin exprs) (emit-begin strings env depth lc exprs)]))

(define (function-frame-size [params : StrList] [body : Expr]) : i64
  (round-up-16 (* 8 (+ (str-list-count params) (max-let-depth body)))))

(define (emit-def [strings : StrList] [lc : (Array i64)] [item : Item]) : String
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
                     (string-append (emit-expr-in strings (bind-params params 1 (sym-i64-empty)) nparams lc body)
                       (string-append "    mov %rbp, %rsp\n"
                         (string-append "    pop %rbp\n"
                           "    ret\n\n")))))))))))]))

(define (emit-defs [strings : StrList] [lc : (Array i64)] [items : ItemList]) : String
  (match items
    [(ILNil) ""]
    [(ILCons item rest) (string-append (emit-def strings lc item) (emit-defs strings lc rest))]))

(define (emit-expr [e : Expr]) : String
  (let ([lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (emit-expr-in (collect-strings e SLNil) (sym-i64-empty) 0 lc e))))

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
        [strings : StrList (collect-strings e (collect-items-strings defs SLNil))]
        [lc : (Array i64) (make-array i64 1)])
    (begin
      (array-set! lc 0 0)
      (string-append (emit-rodata strings)
        (string-append "    .text\n"
          (string-append "    .globl main\n"
            (string-append "    .globl _start\n\n"
              (string-append (emit-defs strings lc defs)
                (emit-entry frame (emit-expr-in strings (sym-i64-empty) 0 lc e))))))))))

(define (emit-program [e : Expr]) : String
  (emit-program-with-defs ILNil e))
