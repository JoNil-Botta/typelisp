;; compiler_backend.tl - First selfhost CompilerIrProgram -> x86_64 .s emitter (#447).

(import "compiler_lower.tl")
(import "text_buf.tl")

(defenum ResultBackendReg
  (OkBackendReg String)
  (ErrBackendReg String))

(defenum ResultBackendValue
  (OkBackendValue CompilerIrValue)
  (ErrBackendValue String))

(defenum ResultCompilerBackend
  (OkCompilerBackend String)
  (ErrCompilerBackend String))

(define (backend-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (backend-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (backend-cat5 [a : String] [b : String] [c : String] [d : String] [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (compiler-backend-round-up-16 [n : i64]) : i64
  (if (= n 0)
      0
      (* (/ (+ n 15) 16) 16)))

(define (compiler-backend-frame-size [vars : i64]) : i64
  (compiler-backend-round-up-16 (* vars 8)))

(define (compiler-backend-slot [var-id : i64]) : String
  (string-append (int->string (- 0 (* 8 (+ var-id 1)))) "(%rbp)"))

(define (compiler-backend-asm-label [function : String] [label : String]) : String
  (backend-cat4 ".L" function "_" label))

(define (compiler-backend-arg-reg [idx : i64]) : ResultBackendReg
  (if (= idx 0)
      (OkBackendReg "%rdi")
      (if (= idx 1)
          (OkBackendReg "%rsi")
          (if (= idx 2)
              (OkBackendReg "%rdx")
              (if (= idx 3)
                  (OkBackendReg "%rcx")
                  (if (= idx 4)
                      (OkBackendReg "%r8")
                      (if (= idx 5)
                          (OkBackendReg "%r9")
                          (ErrBackendReg "backend: too many call args"))))))))

(define (compiler-backend-emit-stack-sub [frame : i64]) : String
  (if (= frame 0)
      ""
      (backend-cat4 "    subq $" (int->string frame) ", %rsp\n" "")))

(define (compiler-backend-emit-store-var [var-id : i64] [reg : String]) : String
  (backend-cat5 "    movq " reg ", " (compiler-backend-slot var-id) "\n"))

(define (compiler-backend-char-code [c : char]) : i64
  (cast c : i64))

(define (compiler-backend-emit-load-value [value : CompilerIrValue] [reg : String]) : ResultCompilerBackend
  (match value
    [(IrValueVar id) (OkCompilerBackend (backend-cat5 "    movq " (compiler-backend-slot id) ", " reg "\n"))]
    [(IrValueGlobal name) (OkCompilerBackend (backend-cat5 "    movq " name "(%rip), " reg "\n"))]
    [(IrValueI64 n) (OkCompilerBackend (backend-cat5 "    movq $" (int->string n) ", " reg "\n"))]
    [(IrValueBool b)
     (if b
         (OkCompilerBackend (backend-cat5 "    movq $" "1" ", " reg "\n"))
         (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n")))]
    [(IrValueChar c) (OkCompilerBackend (backend-cat5 "    movq $" (int->string (compiler-backend-char-code c)) ", " reg "\n"))]
    [(IrValueUnit) (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n"))]
    [(IrValueF64 _) (ErrCompilerBackend "backend: f64 values are not supported yet")]
    [(IrValueString _) (ErrCompilerBackend "backend: String values are not supported yet")]))

(define (compiler-backend-binop-asm [op : CompilerIrBinOp]) : String
  (match op
    [(IrBinAdd) "    addq %rbx, %rax\n"]
    [(IrBinSub) "    subq %rbx, %rax\n"]
    [(IrBinMul) "    imulq %rbx, %rax\n"]
    [(IrBinDiv) "    cqto\n    idivq %rbx\n"]
    [(IrBinMod) "    cqto\n    idivq %rbx\n    movq %rdx, %rax\n"]
    [(IrBinEq) "    cmpq %rbx, %rax\n    sete %al\n    movzbq %al, %rax\n"]
    [(IrBinNe) "    cmpq %rbx, %rax\n    setne %al\n    movzbq %al, %rax\n"]
    [(IrBinLt) "    cmpq %rbx, %rax\n    setl %al\n    movzbq %al, %rax\n"]
    [(IrBinLe) "    cmpq %rbx, %rax\n    setle %al\n    movzbq %al, %rax\n"]
    [(IrBinGt) "    cmpq %rbx, %rax\n    setg %al\n    movzbq %al, %rax\n"]
    [(IrBinGe) "    cmpq %rbx, %rax\n    setge %al\n    movzbq %al, %rax\n"]
    [(IrBinAnd) "    andq %rbx, %rax\n"]
    [(IrBinOr) "    orq %rbx, %rax\n"]
    [(IrBinBitAnd) "    andq %rbx, %rax\n"]
    [(IrBinBitOr) "    orq %rbx, %rax\n"]
    [(IrBinBitXor) "    xorq %rbx, %rax\n"]
    [(IrBinShl) "    movq %rbx, %rcx\n    shlq %cl, %rax\n"]
    [(IrBinShr) "    movq %rbx, %rcx\n    sarq %cl, %rax\n"]))

(define (compiler-backend-unop-asm [op : CompilerIrUnOp]) : String
  (match op
    [(IrUnNeg) "    negq %rax\n"]
    [(IrUnNot) "    cmpq $0, %rax\n    sete %al\n    movzbq %al, %rax\n"]
    [(IrUnBitNot) "    notq %rax\n"]))

(define (compiler-backend-emit-binop [dst : i64] [op : CompilerIrBinOp] [lhs : CompilerIrValue] [rhs : CompilerIrValue]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value lhs "%rax")
    [(OkCompilerBackend lhs-asm)
     (match (compiler-backend-emit-load-value rhs "%rbx")
       [(OkCompilerBackend rhs-asm)
        (OkCompilerBackend
          (string-append lhs-asm
            (string-append rhs-asm
              (string-append (compiler-backend-binop-asm op)
                (compiler-backend-emit-store-var dst "%rax")))))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-unop [dst : i64] [op : CompilerIrUnOp] [src : CompilerIrValue]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value src "%rax")
    [(OkCompilerBackend src-asm)
     (OkCompilerBackend
       (string-append src-asm
         (string-append (compiler-backend-unop-asm op)
           (compiler-backend-emit-store-var dst "%rax"))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-call-args [args : CompilerIrValueList] [idx : i64]) : ResultCompilerBackend
  (match args
    [(IrValueNil) (OkCompilerBackend "")]
    [(IrValueCons value rest)
     (match (compiler-backend-arg-reg idx)
       [(OkBackendReg reg)
        (match (compiler-backend-emit-load-value value reg)
          [(OkCompilerBackend head)
           (match (compiler-backend-emit-call-args rest (+ idx 1))
             [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
             [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrBackendReg message) (ErrCompilerBackend message)])]))

(define (compiler-backend-phi-input-value [inputs : CompilerIrPhiInputList] [from-label : String]) : ResultBackendValue
  (match inputs
    [(IrPhiInputNil) (ErrBackendValue (string-append "backend: missing phi input from " from-label))]
    [(IrPhiInputCons input rest)
     (match input
       [(IrPhiInput value label)
        (if (string-eq label from-label)
            (OkBackendValue value)
            (compiler-backend-phi-input-value rest from-label))])]))

(define (compiler-backend-emit-phi-copy [dst : i64] [inputs : CompilerIrPhiInputList] [from-label : String]) : ResultCompilerBackend
  (match (compiler-backend-phi-input-value inputs from-label)
    [(OkBackendValue value)
     (match (compiler-backend-emit-load-value value "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend (string-append load (compiler-backend-emit-store-var dst "%rax")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrBackendValue message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-leading-phi-copies [instrs : CompilerIrInstrList] [from-label : String]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
     (match instr
       [(IrInstrPhi dst inputs _)
        (match (compiler-backend-emit-phi-copy dst inputs from-label)
          [(OkCompilerBackend asm)
           (match (compiler-backend-emit-leading-phi-copies rest from-label)
             [(OkCompilerBackend tail) (OkCompilerBackend (string-append asm tail))]
             [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [_ (OkCompilerBackend "")])]))

(define (compiler-backend-emit-phi-edge-copies [blocks : CompilerIrBlockList] [target-label : String] [from-label : String]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (ErrCompilerBackend (string-append "backend: unknown block " target-label))]
    [(IrBlockCons block rest)
     (match block
       [(IrBlock block-label instrs)
        (if (string-eq block-label target-label)
            (compiler-backend-emit-leading-phi-copies instrs from-label)
            (compiler-backend-emit-phi-edge-copies rest target-label from-label))])]))

(define (compiler-backend-emit-return [value : CompilerIrMaybeValue]) : ResultCompilerBackend
  (match value
    [(IrNoValue) (OkCompilerBackend "    movq $0, %rax\n    movq %rbp, %rsp\n    popq %rbp\n    ret\n")]
    [(IrSomeValue v)
     (match (compiler-backend-emit-load-value v "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend (string-append load "    movq %rbp, %rsp\n    popq %rbp\n    ret\n"))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-instr [function : String] [blocks : CompilerIrBlockList] [current-label : String] [instr : CompilerIrInstr]) : ResultCompilerBackend
  (match instr
    [(IrInstrMov dst src _) 
     (match (compiler-backend-emit-load-value src "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend (string-append load (compiler-backend-emit-store-var dst "%rax")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrBinOp dst op lhs rhs _) (compiler-backend-emit-binop dst op lhs rhs)]
    [(IrInstrUnOp dst op src _) (compiler-backend-emit-unop dst op src)]
    [(IrInstrCall dst name args _)
     (match (compiler-backend-emit-call-args args 0)
       [(OkCompilerBackend args-asm)
        (OkCompilerBackend
          (string-append args-asm
            (backend-cat5 "    call " name "\n" (compiler-backend-emit-store-var dst "%rax") "")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrStore name value _)
     (match (compiler-backend-emit-load-value value "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend (string-append load (backend-cat4 "    movq %rax, " name "(%rip)\n" "")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrJump target)
     (match (compiler-backend-emit-phi-edge-copies blocks target current-label)
       [(OkCompilerBackend copies)
        (OkCompilerBackend
          (string-append copies
            (backend-cat4 "    jmp " (compiler-backend-asm-label function target) "\n" "")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrBranch cond true-label false-label)
     (match (compiler-backend-emit-load-value cond "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend
          (string-append load
            (string-append "    cmpq $0, %rax\n"
              (backend-cat5
                "    jne "
                (compiler-backend-asm-label function true-label)
                "\n    jmp "
                (compiler-backend-asm-label function false-label)
                "\n"))))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrReturn value) (compiler-backend-emit-return value)]
    [(IrInstrPhi _ _ _) (OkCompilerBackend "")]))

(define (compiler-backend-emit-instrs [function : String] [blocks : CompilerIrBlockList] [current-label : String] [instrs : CompilerIrInstrList]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
     (match (compiler-backend-emit-instr function blocks current-label instr)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-instrs function blocks current-label rest)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-block [function : String] [blocks : CompilerIrBlockList] [block : CompilerIrBlock]) : ResultCompilerBackend
  (match block
    [(IrBlock label instrs)
     (match (compiler-backend-emit-instrs function blocks label instrs)
       [(OkCompilerBackend body)
        (OkCompilerBackend
          (backend-cat4 (compiler-backend-asm-label function label) ":\n" body ""))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-blocks [function : String] [all-blocks : CompilerIrBlockList] [blocks : CompilerIrBlockList]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
     (match (compiler-backend-emit-block function all-blocks block)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-blocks function all-blocks rest)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-param-spills [params : CompilerIrParamList] [idx : i64]) : ResultCompilerBackend
  (match params
    [(IrParamNil) (OkCompilerBackend "")]
    [(IrParamCons param rest)
     (match (compiler-backend-arg-reg idx)
       [(OkBackendReg reg)
        (match param
          [(IrParam _ _ var-id)
           (match (compiler-backend-emit-param-spills rest (+ idx 1))
             [(OkCompilerBackend tail)
              (OkCompilerBackend
                (string-append (compiler-backend-emit-store-var var-id reg) tail))]
             [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
       [(ErrBackendReg _) (ErrCompilerBackend "backend: too many params")])]))

(define (compiler-backend-emit-function [func : CompilerIrFunction]) : ResultCompilerBackend
  (match func
    [(IrFunction name params _ vars blocks)
     (match (compiler-backend-emit-param-spills params 0)
       [(OkCompilerBackend spills)
        (match (compiler-backend-emit-blocks name blocks blocks)
          [(OkCompilerBackend body)
           (let ([frame : i64 (compiler-backend-frame-size vars)])
             (OkCompilerBackend
               (backend-cat5
                 ".globl "
                 name
                 "\n"
                 (backend-cat5
                   name
                   ":\n    pushq %rbp\n    movq %rsp, %rbp\n"
                   (compiler-backend-emit-stack-sub frame)
                   (string-append spills body)
                   "\n")
                 "")))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-functions [functions : CompilerIrFunctionList]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend "")]
    [(IrFunctionCons func rest)
     (match (compiler-backend-emit-function func)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-functions rest)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-global-value-asm [value : CompilerIrValue]) : ResultCompilerBackend
  (match value
    [(IrValueI64 n) (OkCompilerBackend (backend-cat3 "    .quad " (int->string n) "\n"))]
    [(IrValueBool b)
     (if b
         (OkCompilerBackend "    .quad 1\n")
         (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueChar c) (OkCompilerBackend (backend-cat3 "    .quad " (int->string (compiler-backend-char-code c)) "\n"))]
    [(IrValueUnit) (OkCompilerBackend "    .quad 0\n")]
    [(IrValueGlobal name) (OkCompilerBackend (backend-cat3 "    .quad " name "\n"))]
    [_ (ErrCompilerBackend "backend: unsupported global initializer")]))

(define (compiler-backend-emit-global [global : CompilerIrGlobal]) : ResultCompilerBackend
  (match global
    [(IrGlobal name _ value)
     (match (compiler-backend-global-value-asm value)
       [(OkCompilerBackend value-asm)
        (OkCompilerBackend (backend-cat5 ".globl " name "\n" (backend-cat3 name ":\n" value-asm) ""))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-globals [globals : CompilerIrGlobalList]) : ResultCompilerBackend
  (match globals
    [(IrGlobalNil) (OkCompilerBackend "")]
    [(IrGlobalCons global rest)
     (match (compiler-backend-emit-global global)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-globals rest)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-externs [externs : CompilerIrExternList]) : String
  (match externs
    [(IrExternNil) ""]
    [(IrExternCons item rest)
     (match item
       [(IrExtern name _) (backend-cat4 ".extern " name "\n" (compiler-backend-emit-externs rest))])]))

(define (compiler-backend-entry) : String
  "_start:\n    call main\n    movq %rax, %rdi\n    movq $60, %rax\n    syscall\n")

(define (compiler-backend-emit-program [program : CompilerIrProgram]) : ResultCompilerBackend
  (match program
    [(IrProgram globals functions externs)
     (match (compiler-backend-emit-globals globals)
       [(OkCompilerBackend globals-asm)
        (match (compiler-backend-emit-functions functions)
          [(OkCompilerBackend functions-asm)
           (let ([buf : TextBuf
                  (text-buf-append
                    (text-buf-append
                      (text-buf-append
                        (text-buf-append
                          (text-buf-append
                            (text-buf-append (text-buf-empty) ".data\n")
                            globals-asm)
                          (compiler-backend-emit-externs externs))
                        ".text\n.globl _start\n")
                      functions-asm)
                    (compiler-backend-entry))])
             (OkCompilerBackend (text-buf-render buf)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-source [src : String]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program) (compiler-backend-emit-program program)]
    [(ErrCompilerLower message) (ErrCompilerBackend message)]))

(define (compiler-backend-char-code-at [text : String] [idx : i64]) : i64
  (compiler-backend-char-code (string-ref text idx)))

(define (compiler-backend-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
        [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
        false
        (if (> (+ start prefix-len) text-len)
            false
            (let ([i : i64 0]
                  [ok : bool true])
              (begin
                (while ok
                  (if (< i prefix-len)
                      (if (= (compiler-backend-char-code-at text (+ start i))
                             (compiler-backend-char-code-at prefix i))
                          (set! i (+ i 1))
                          (set! ok false))
                      (set! ok false)))
                (= i prefix-len)))))))

(define (compiler-backend-string-contains? [text : String] [needle : String]) : bool
  (let ([text-len : i64 (string-length text)]
        [needle-len : i64 (string-length needle)])
    (if (= needle-len 0)
        true
        (let ([i : i64 0]
              [found : bool false]
              [done : bool false])
          (begin
            (while (not done)
              (if (<= (+ i needle-len) text-len)
                  (if (compiler-backend-string-prefix-at? text needle i)
                      (begin
                        (set! found true)
                        (set! done true))
                      (set! i (+ i 1)))
                  (set! done true)))
            found)))))

(define (compiler-backend-smoke-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (let ([x : i64 (inc answer)])
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if (> x 44) x 0))))")

(define (compiler-backend-too-many-call-source) : String
  "(extern f : (-> i64 i64 i64 i64 i64 i64 i64 i64))
(define (main) : i64 (f 1 2 3 4 5 6 7))")

(define (compiler-backend-asm-ok? [asm : String]) : bool
  (and (compiler-backend-string-contains? asm ".data\n")
       (and (compiler-backend-string-contains? asm ".text\n")
            (and (compiler-backend-string-contains? asm ".globl _start\n")
                 (and (compiler-backend-string-contains? asm "_start:\n")
                      (and (compiler-backend-string-contains? asm "main:\n")
                           (and (compiler-backend-string-contains? asm "inc:\n")
                                (and (compiler-backend-string-contains? asm "answer:\n")
                                     (and (compiler-backend-string-contains? asm "    call inc\n")
                                          (and (compiler-backend-string-contains? asm "    setl %al\n")
                                               (and (compiler-backend-string-contains? asm "    setg %al\n")
                                                    (and (compiler-backend-string-contains? asm "    cmpq $0, %rax\n")
                                                         (and (compiler-backend-string-contains? asm "    jne .Lmain_while_body.1\n")
                                                              (compiler-backend-string-contains? asm "    jmp .Lmain_while_header.0\n"))))))))))))))

(define (compiler-backend-source-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-asm-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-deterministic-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend first)
     (match (compiler-backend-emit-source src)
       [(OkCompilerBackend second) (string-eq first second)]
       [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-error-ok? [src : String] [want : String]) : bool
  (match (compiler-backend-emit-source src)
    [(ErrCompilerBackend message) (string-eq message want)]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-self-test) : i64
  (if (and (compiler-backend-source-ok? (compiler-backend-smoke-source))
           (and (compiler-backend-deterministic-ok? (compiler-backend-smoke-source))
                (compiler-backend-error-ok? (compiler-backend-too-many-call-source)
                                            "backend: too many call args")))
      42
      (begin
        (panic "backend: smoke output mismatch")
        0)))
