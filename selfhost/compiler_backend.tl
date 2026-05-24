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

(defenum CompilerBackendRuntimePlan
  (BackendRuntimePlan bool bool bool bool))

(defenum ResultBackendRuntimePlan
  (OkBackendRuntimePlan CompilerBackendRuntimePlan)
  (ErrBackendRuntimePlan String))

(defenum BackendStringList
  (BackendStringNil)
  (BackendStringCons String BackendStringList))

(define (backend-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (backend-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (backend-cat5 [a : String] [b : String] [c : String] [d : String] [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (backend-and4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (and a (and b (and c d))))

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

(define (compiler-backend-symbol-char [text : String] [idx : i64] [k : i64]) : String
  (if (or (and (>= k 65) (<= k 90))
          (or (and (>= k 97) (<= k 122))
              (or (and (>= k 48) (<= k 57))
                  (= k 95))))
      (substring text idx 1)
      (if (= k 45)
          "_"
          (if (= k 63)
              "_question"
              (if (= k 33)
                  "_bang"
                  (if (= k 43)
                      "_plus"
                      (if (= k 42)
                          "_star"
                          (if (= k 47)
                              "_slash"
                              (if (= k 61)
                                  "_eq"
                                  (if (= k 60)
                                      "_lt"
                                      (if (= k 62)
                                          "_gt"
                                          (if (= k 58)
                                              "_colon"
                                              (string-append "_u" (compiler-backend-hex-byte k))))))))))))))

(define (compiler-backend-asm-safe-symbol [name : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length name)]
        [out : String ""])
    (begin
      (while (< i n)
        (let ([k : i64 (compiler-backend-char-code-at name i)])
          (begin
            (set! out (string-append out (compiler-backend-symbol-char name i k)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-user-symbol [name : String]) : String
  (if (string-eq name "main")
      "main"
      (string-append "_tl_" (compiler-backend-asm-safe-symbol name))))

(define (compiler-backend-call-symbol [name : String] [plan : CompilerBackendRuntimePlan] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : String
  (if (and (compiler-backend-plan-provides? plan name)
           (not (compiler-backend-function-list-defines? functions name)))
      name
      (if (compiler-backend-extern-list-references? externs name)
          (compiler-backend-asm-safe-symbol name)
          (compiler-backend-user-symbol name))))

(define (compiler-backend-type-size [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 0]
    [(AstTyNever) 0]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem count) (* (compiler-backend-type-size elem) count)]
    [(AstTyDynArray _) 8]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyVar _) 8]))

(define (compiler-backend-type-signed? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [_ false]))

(define (compiler-backend-hex-digit [n : i64]) : String
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
                              (if (= n 7)
                                  "7"
                                  (if (= n 8)
                                      "8"
                                      (if (= n 9)
                                          "9"
                                          (if (= n 10)
                                              "a"
                                              (if (= n 11)
                                                  "b"
                                                  (if (= n 12)
                                                      "c"
                                                      (if (= n 13)
                                                          "d"
                                                          (if (= n 14)
                                                              "e"
                                                              "f"))))))))))))))))

(define (compiler-backend-hex-byte [n : i64]) : String
  (string-append (compiler-backend-hex-digit (/ n 16))
                 (compiler-backend-hex-digit (% n 16))))

(define (compiler-backend-octal-digit [n : i64]) : String
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

(define (compiler-backend-octal-escape [n : i64]) : String
  (string-append "\\"
    (string-append (compiler-backend-octal-digit (/ n 64))
      (string-append (compiler-backend-octal-digit (% (/ n 8) 8))
        (compiler-backend-octal-digit (% n 8))))))

(define (compiler-backend-escape-string-byte [text : String] [idx : i64] [k : i64]) : String
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
                          (compiler-backend-octal-escape k))))))))

(define (compiler-backend-escape-string [text : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length text)]
        [out : String ""])
    (begin
      (while (< i n)
        (let ([k : i64 (compiler-backend-char-code-at text i)])
          (begin
            (set! out (string-append out (compiler-backend-escape-string-byte text i k)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-quoted-gas-string [text : String]) : String
  (string-append "\"" (string-append (compiler-backend-escape-string text) "\"")))

(define (compiler-backend-string-label-suffix [text : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length text)]
        [out : String ""])
    (begin
      (while (< i n)
        (begin
          (set! out
                (string-append out
                               (compiler-backend-hex-byte
                                 (compiler-backend-char-code-at text i))))
          (set! i (+ i 1))))
      (if (= n 0) "empty" out))))

(define (compiler-backend-string-data-label [text : String]) : String
  (string-append ".L_tl_str_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-string-fat-label [text : String]) : String
  (string-append ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-emit-load-value [value : CompilerIrValue] [reg : String]) : ResultCompilerBackend
  (match value
    [(IrValueVar id) (OkCompilerBackend (backend-cat5 "    movq " (compiler-backend-slot id) ", " reg "\n"))]
    [(IrValueGlobal name)
     (OkCompilerBackend
       (backend-cat5 "    movq " (compiler-backend-user-symbol name) "(%rip), " reg "\n"))]
    [(IrValueI64 n) (OkCompilerBackend (backend-cat5 "    movq $" (int->string n) ", " reg "\n"))]
    [(IrValueBool b)
     (if b
         (OkCompilerBackend (backend-cat5 "    movq $" "1" ", " reg "\n"))
         (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n")))]
    [(IrValueChar c) (OkCompilerBackend (backend-cat5 "    movq $" (int->string (compiler-backend-char-code c)) ", " reg "\n"))]
    [(IrValueUnit) (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n"))]
    [(IrValueF64 _) (ErrCompilerBackend "backend: f64 values are not supported yet")]
    [(IrValueString text)
     (OkCompilerBackend
       (backend-cat5 "    leaq " (compiler-backend-string-fat-label text) "(%rip), " reg "\n"))]))

(define (compiler-backend-emit-load-memory [addr : String] [ty : AstType]) : String
  (let ([size : i64 (compiler-backend-type-size ty)])
    (if (= size 8)
        (backend-cat3 "    movq " addr ", %rax\n")
        (if (= size 4)
            (if (compiler-backend-type-signed? ty)
                (backend-cat3 "    movslq " addr ", %rax\n")
                (backend-cat3 "    movl " addr ", %eax\n"))
            (if (= size 2)
                (if (compiler-backend-type-signed? ty)
                    (backend-cat3 "    movswq " addr ", %rax\n")
                    (backend-cat3 "    movzwq " addr ", %rax\n"))
                (if (= size 1)
                    (if (compiler-backend-type-signed? ty)
                        (backend-cat3 "    movsbq " addr ", %rax\n")
                        (backend-cat3 "    movzbq " addr ", %rax\n"))
                    ""))))))

(define (compiler-backend-emit-store-rax-to-memory [addr : String] [ty : AstType]) : String
  (let ([size : i64 (compiler-backend-type-size ty)])
    (if (= size 8)
        (backend-cat3 "    movq %rax, " addr "\n")
        (if (= size 4)
            (backend-cat3 "    movl %eax, " addr "\n")
            (if (= size 2)
                (backend-cat3 "    movw %ax, " addr "\n")
                (if (= size 1)
                    (backend-cat3 "    movb %al, " addr "\n")
                    ""))))))

(define (compiler-backend-emit-load-typed-value [value : CompilerIrValue] [ty : AstType]) : ResultCompilerBackend
  (match value
    [(IrValueVar id)
     (OkCompilerBackend (compiler-backend-emit-load-memory (compiler-backend-slot id) ty))]
    [(IrValueGlobal name)
     (OkCompilerBackend
       (compiler-backend-emit-load-memory
         (backend-cat3 (compiler-backend-user-symbol name) "(%rip)" "")
         ty))]
    [_ (compiler-backend-emit-load-value value "%rax")]))

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

(define (compiler-backend-emit-addr-of [dst : i64] [src : i64]) : ResultCompilerBackend
  (OkCompilerBackend
    (string-append
      (backend-cat5 "    leaq " (compiler-backend-slot src) ", " "%rax" "\n")
      (compiler-backend-emit-store-var dst "%rax"))))

(define (compiler-backend-emit-gep [dst : i64] [base : CompilerIrValue] [offset : CompilerIrValue] [elem-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value base "%rax")
    [(OkCompilerBackend base-asm)
     (match (compiler-backend-emit-load-value offset "%rbx")
       [(OkCompilerBackend offset-asm)
        (let ([scale : i64 (compiler-backend-type-size elem-ty)])
          (OkCompilerBackend
            (string-append base-asm
              (string-append offset-asm
                (string-append
                  (if (= scale 1)
                      ""
                      (backend-cat5 "    imulq $" (int->string scale) ", " "%rbx" "\n"))
                  (string-append
                    "    addq %rbx, %rax\n"
                    (compiler-backend-emit-store-var dst "%rax")))))))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-load-instr [dst : i64] [src : CompilerIrValue] [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value src "%r10")
    [(OkCompilerBackend ptr-asm)
     (OkCompilerBackend
       (string-append ptr-asm
         (string-append (compiler-backend-emit-load-memory "(%r10)" ty)
                        (compiler-backend-emit-store-var dst "%rax"))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-store-ptr [dst : CompilerIrValue] [src : CompilerIrValue] [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value dst "%r10")
    [(OkCompilerBackend ptr-asm)
     (match (compiler-backend-emit-load-typed-value src ty)
       [(OkCompilerBackend src-asm)
        (OkCompilerBackend
          (string-append ptr-asm
            (string-append src-asm
                           (compiler-backend-emit-store-rax-to-memory "(%r10)" ty))))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-cast [dst : i64] [src : CompilerIrValue] [from-ty : AstType] [to-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-typed-value src from-ty)
    [(OkCompilerBackend load)
     (OkCompilerBackend
       (string-append load
         (compiler-backend-emit-store-var dst "%rax")))]
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

(define (compiler-backend-emit-instr [function : String] [blocks : CompilerIrBlockList] [current-label : String] [instr : CompilerIrInstr] [plan : CompilerBackendRuntimePlan] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match instr
    [(IrInstrMov dst src _) 
     (match (compiler-backend-emit-load-value src "%rax")
       [(OkCompilerBackend load)
        (OkCompilerBackend (string-append load (compiler-backend-emit-store-var dst "%rax")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrAlloc _ _) (OkCompilerBackend "")]
    [(IrInstrAddrOf dst src) (compiler-backend-emit-addr-of dst src)]
    [(IrInstrGep dst base offset elem-ty) (compiler-backend-emit-gep dst base offset elem-ty)]
    [(IrInstrLoad dst src ty) (compiler-backend-emit-load-instr dst src ty)]
    [(IrInstrStorePtr dst src ty) (compiler-backend-emit-store-ptr dst src ty)]
    [(IrInstrCast dst src from-ty to-ty) (compiler-backend-emit-cast dst src from-ty to-ty)]
    [(IrInstrBinOp dst op lhs rhs _) (compiler-backend-emit-binop dst op lhs rhs)]
    [(IrInstrUnOp dst op src _) (compiler-backend-emit-unop dst op src)]
    [(IrInstrCall dst name args _)
     (match (compiler-backend-emit-call-args args 0)
       [(OkCompilerBackend args-asm)
        (OkCompilerBackend
          (string-append args-asm
            (backend-cat5
              "    call "
              (compiler-backend-call-symbol name plan functions externs)
              "\n"
              (compiler-backend-emit-store-var dst "%rax")
              "")))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrStore name value _)
      (match (compiler-backend-emit-load-value value "%rax")
        [(OkCompilerBackend load)
         (OkCompilerBackend
           (string-append
             load
             (backend-cat4 "    movq %rax, " (compiler-backend-user-symbol name) "(%rip)\n" "")))]
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

(define (compiler-backend-emit-instrs [function : String] [blocks : CompilerIrBlockList] [current-label : String] [instrs : CompilerIrInstrList] [plan : CompilerBackendRuntimePlan] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
     (match (compiler-backend-emit-instr function blocks current-label instr plan functions externs)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-instrs function blocks current-label rest plan functions externs)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-block [function : String] [blocks : CompilerIrBlockList] [block : CompilerIrBlock] [plan : CompilerBackendRuntimePlan] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match block
    [(IrBlock label instrs)
     (match (compiler-backend-emit-instrs function blocks label instrs plan functions externs)
       [(OkCompilerBackend body)
        (OkCompilerBackend
          (backend-cat4 (compiler-backend-asm-label function label) ":\n" body ""))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-blocks [function : String] [all-blocks : CompilerIrBlockList] [blocks : CompilerIrBlockList] [plan : CompilerBackendRuntimePlan] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
     (match (compiler-backend-emit-block function all-blocks block plan functions externs)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-blocks function all-blocks rest plan functions externs)
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

(define (compiler-backend-emit-function [func : CompilerIrFunction] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList] [plan : CompilerBackendRuntimePlan]) : ResultCompilerBackend
  (match func
    [(IrFunction name params _ vars blocks)
     (match (compiler-backend-emit-param-spills params 0)
        [(OkCompilerBackend spills)
         (let ([symbol : String (compiler-backend-user-symbol name)])
           (match (compiler-backend-emit-blocks symbol blocks blocks plan functions externs)
             [(OkCompilerBackend body)
              (let ([frame : i64 (compiler-backend-frame-size vars)])
                (OkCompilerBackend
                  (backend-cat5
                  ".globl "
                  symbol
                  "\n"
                  (backend-cat5
                    symbol
                    ":\n    pushq %rbp\n    movq %rsp, %rbp\n"
                    (compiler-backend-emit-stack-sub frame)
                    (string-append spills body)
                    "\n")
                  "")))]
             [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-functions [functions : CompilerIrFunctionList] [all-functions : CompilerIrFunctionList] [externs : CompilerIrExternList] [plan : CompilerBackendRuntimePlan]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend "")]
    [(IrFunctionCons func rest)
     (match (compiler-backend-emit-function func all-functions externs plan)
       [(OkCompilerBackend head)
        (match (compiler-backend-emit-functions rest all-functions externs plan)
          [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
       [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-string-list-contains? [strings : BackendStringList] [text : String]) : bool
  (match strings
    [(BackendStringNil) false]
    [(BackendStringCons head rest)
     (if (string-eq head text)
         true
         (compiler-backend-string-list-contains? rest text))]))

(define (compiler-backend-string-list-append [strings : BackendStringList] [text : String]) : BackendStringList
  (match strings
    [(BackendStringNil) (BackendStringCons text BackendStringNil)]
    [(BackendStringCons head rest)
     (BackendStringCons head (compiler-backend-string-list-append rest text))]))

(define (compiler-backend-string-list-add [strings : BackendStringList] [text : String]) : BackendStringList
  (if (compiler-backend-string-list-contains? strings text)
      strings
      (compiler-backend-string-list-append strings text)))

(define (compiler-backend-collect-value-string [strings : BackendStringList] [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueString text) (compiler-backend-string-list-add strings text)]
    [_ strings]))

(define (compiler-backend-collect-value-list-strings [strings : BackendStringList] [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) strings]
    [(IrValueCons value rest)
     (compiler-backend-collect-value-list-strings
       (compiler-backend-collect-value-string strings value)
       rest)]))

(define (compiler-backend-collect-phi-strings [strings : BackendStringList] [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) strings]
    [(IrPhiInputCons input rest)
     (match input
       [(IrPhiInput value _)
        (compiler-backend-collect-phi-strings
          (compiler-backend-collect-value-string strings value)
          rest)])]))

(define (compiler-backend-collect-instr-strings [strings : BackendStringList] [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrBinOp _ _ lhs rhs _)
     (compiler-backend-collect-value-string
       (compiler-backend-collect-value-string strings lhs)
       rhs)]
    [(IrInstrUnOp _ _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrCall _ _ args _) (compiler-backend-collect-value-list-strings strings args)]
    [(IrInstrStore _ value _) (compiler-backend-collect-value-string strings value)]
    [(IrInstrBranch cond _ _) (compiler-backend-collect-value-string strings cond)]
    [(IrInstrReturn maybe)
     (match maybe
       [(IrNoValue) strings]
       [(IrSomeValue value) (compiler-backend-collect-value-string strings value)])]
    [(IrInstrPhi _ inputs _) (compiler-backend-collect-phi-strings strings inputs)]
    [(IrInstrGep _ base offset _)
     (compiler-backend-collect-value-string
       (compiler-backend-collect-value-string strings base)
       offset)]
    [(IrInstrLoad _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrStorePtr dst src _)
     (compiler-backend-collect-value-string
       (compiler-backend-collect-value-string strings dst)
       src)]
    [(IrInstrCast _ src _ _) (compiler-backend-collect-value-string strings src)]
    [_ strings]))

(define (compiler-backend-collect-instr-list-strings [strings : BackendStringList] [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) strings]
    [(IrInstrCons instr rest)
     (compiler-backend-collect-instr-list-strings
       (compiler-backend-collect-instr-strings strings instr)
       rest)]))

(define (compiler-backend-collect-block-strings [strings : BackendStringList] [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) strings]
    [(IrBlockCons block rest)
     (match block
       [(IrBlock _ instrs)
        (compiler-backend-collect-block-strings
          (compiler-backend-collect-instr-list-strings strings instrs)
          rest)])]))

(define (compiler-backend-collect-function-strings [strings : BackendStringList] [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) strings]
    [(IrFunctionCons func rest)
     (match func
       [(IrFunction _ _ _ _ blocks)
        (compiler-backend-collect-function-strings
          (compiler-backend-collect-block-strings strings blocks)
          rest)])]))

(define (compiler-backend-collect-global-strings [strings : BackendStringList] [globals : CompilerIrGlobalList]) : BackendStringList
  (match globals
    [(IrGlobalNil) strings]
    [(IrGlobalCons global rest)
     (match global
       [(IrGlobal _ _ value)
        (compiler-backend-collect-global-strings
          (compiler-backend-collect-value-string strings value)
          rest)])]))

(define (compiler-backend-collect-program-strings [program : CompilerIrProgram]) : BackendStringList
  (match program
    [(IrProgram globals functions _)
     (compiler-backend-collect-function-strings
       (compiler-backend-collect-global-strings BackendStringNil globals)
       functions)]))

(define (compiler-backend-emit-string-entry [text : String]) : String
  (backend-cat5
    (compiler-backend-string-data-label text)
    ":\n    .string "
    (compiler-backend-quoted-gas-string text)
    "\n    .balign 8\n"
    (backend-cat5
      (compiler-backend-string-fat-label text)
      ":\n    .quad "
      (compiler-backend-string-data-label text)
      "\n    .quad "
      (backend-cat3 (int->string (string-length text)) "\n" ""))))

(define (compiler-backend-emit-string-entries [strings : BackendStringList]) : String
  (match strings
    [(BackendStringNil) ""]
    [(BackendStringCons text rest)
     (string-append (compiler-backend-emit-string-entry text)
                    (compiler-backend-emit-string-entries rest))]))

(define (compiler-backend-emit-string-rodata [strings : BackendStringList]) : String
  (match strings
    [(BackendStringNil) ""]
    [_ (string-append "    .section .rodata\n"
                      (string-append (compiler-backend-emit-string-entries strings) "\n"))]))

(define (compiler-backend-global-value-asm [value : CompilerIrValue]) : ResultCompilerBackend
  (match value
    [(IrValueI64 n) (OkCompilerBackend (backend-cat3 "    .quad " (int->string n) "\n"))]
    [(IrValueBool b)
     (if b
         (OkCompilerBackend "    .quad 1\n")
         (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueChar c) (OkCompilerBackend (backend-cat3 "    .quad " (int->string (compiler-backend-char-code c)) "\n"))]
    [(IrValueUnit) (OkCompilerBackend "    .quad 0\n")]
    [(IrValueGlobal name)
     (OkCompilerBackend (backend-cat3 "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueString text) (OkCompilerBackend (backend-cat3 "    .quad " (compiler-backend-string-fat-label text) "\n"))]
    [_ (ErrCompilerBackend "backend: unsupported global initializer")]))

(define (compiler-backend-emit-global [global : CompilerIrGlobal]) : ResultCompilerBackend
  (match global
    [(IrGlobal name _ value)
     (match (compiler-backend-global-value-asm value)
       [(OkCompilerBackend value-asm)
        (let ([symbol : String (compiler-backend-user-symbol name)])
          (OkCompilerBackend
            (backend-cat5 ".globl " symbol "\n" (backend-cat3 symbol ":\n" value-asm) "")))]
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

(define (compiler-backend-function-list-defines? [functions : CompilerIrFunctionList] [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
     (match func
       [(IrFunction func-name _ _ _ _)
        (if (string-eq func-name name)
            true
            (compiler-backend-function-list-defines? rest name))])]))

(define (compiler-backend-extern-list-references? [externs : CompilerIrExternList] [name : String]) : bool
  (match externs
    [(IrExternNil) false]
    [(IrExternCons item rest)
     (match item
       [(IrExtern extern-name _)
        (if (string-eq extern-name name)
            true
            (compiler-backend-extern-list-references? rest name))])]))

(define (compiler-backend-instr-calls? [instr : CompilerIrInstr] [name : String]) : bool
  (match instr
    [(IrInstrCall _ call-name _ _) (string-eq call-name name)]
    [_ false]))

(define (compiler-backend-instr-list-calls? [instrs : CompilerIrInstrList] [name : String]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
     (if (compiler-backend-instr-calls? instr name)
         true
         (compiler-backend-instr-list-calls? rest name))]))

(define (compiler-backend-block-list-calls? [blocks : CompilerIrBlockList] [name : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
     (match block
       [(IrBlock _ instrs)
        (if (compiler-backend-instr-list-calls? instrs name)
            true
            (compiler-backend-block-list-calls? rest name))])]))

(define (compiler-backend-function-list-calls? [functions : CompilerIrFunctionList] [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
     (match func
       [(IrFunction _ _ _ _ blocks)
        (if (compiler-backend-block-list-calls? blocks name)
            true
            (compiler-backend-function-list-calls? rest name))])]))

(define (compiler-backend-plan-provides? [plan : CompilerBackendRuntimePlan] [name : String]) : bool
  (match plan
    [(BackendRuntimePlan alloc oob substring concat)
     (if (string-eq name "tl_alloc")
         alloc
         (if (string-eq name "tl_oob_abort")
             oob
             (if (string-eq name "tl_substring")
                 substring
                 (if (string-eq name "tl_string_concat")
                     concat
                     false))))]))

(define (compiler-backend-runtime-plan-for [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultBackendRuntimePlan
  (let ([defines-alloc : bool (compiler-backend-function-list-defines? functions "tl_alloc")]
        [defines-oob : bool (compiler-backend-function-list-defines? functions "tl_oob_abort")]
        [defines-substring : bool (compiler-backend-function-list-defines? functions "tl_substring")]
        [defines-concat : bool (compiler-backend-function-list-defines? functions "tl_string_concat")]
        [extern-alloc : bool (compiler-backend-extern-list-references? externs "tl_alloc")]
        [extern-oob : bool (compiler-backend-extern-list-references? externs "tl_oob_abort")]
        [extern-substring : bool (compiler-backend-extern-list-references? externs "tl_substring")]
        [extern-concat : bool (compiler-backend-extern-list-references? externs "tl_string_concat")]
        [calls-alloc : bool (compiler-backend-function-list-calls? functions "tl_alloc")]
        [calls-oob : bool (compiler-backend-function-list-calls? functions "tl_oob_abort")]
        [calls-substring : bool (compiler-backend-function-list-calls? functions "tl_substring")]
        [calls-concat : bool (compiler-backend-function-list-calls? functions "tl_string_concat")])
    (let ([needs-oob : bool (and (not defines-oob) (or extern-oob calls-oob))]
          [needs-substring : bool (and (not defines-substring) (or extern-substring calls-substring))]
          [needs-concat : bool (and (not defines-concat) (or extern-concat calls-concat))]
          [direct-alloc : bool (and (not defines-alloc) (or extern-alloc calls-alloc))])
      (let ([needs-alloc : bool (or direct-alloc (or needs-substring needs-concat))])
        (OkBackendRuntimePlan
          (BackendRuntimePlan needs-alloc needs-oob needs-substring needs-concat))))))

(define (compiler-backend-runtime-plan [program : CompilerIrProgram]) : ResultBackendRuntimePlan
  (match program
    [(IrProgram _ functions externs) (compiler-backend-runtime-plan-for functions externs)]))

(define (compiler-backend-emit-externs [externs : CompilerIrExternList] [plan : CompilerBackendRuntimePlan]) : String
  (match externs
    [(IrExternNil) ""]
    [(IrExternCons item rest)
     (match item
        [(IrExtern name _)
         (if (compiler-backend-plan-provides? plan name)
             (compiler-backend-emit-externs rest plan)
             (backend-cat4
               ".extern "
               (compiler-backend-asm-safe-symbol name)
               "\n"
               (compiler-backend-emit-externs rest plan)))])]))

(define (compiler-backend-runtime-alloc-data) : String
  "    .section .rodata
.L_tl_alloc_msg:
    .byte 116,108,58,32,97,108,108,111,99,97,116,105,111,110,32,102,97,105,108,101,100,10
    .set .L_tl_alloc_msg_len, . - .L_tl_alloc_msg

")

(define (compiler-backend-runtime-oob-data) : String
  "    .section .rodata
.L_tl_oob_msg:
    .byte 116,108,58,32,97,114,114,97,121,32,105,110,100,101,120,32,111,117,116,32,111,102,32,98,111,117,110,100,115,10
    .set .L_tl_oob_msg_len, . - .L_tl_oob_msg

")

(define (compiler-backend-runtime-data [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan alloc oob _ _)
     (string-append
       (if alloc (compiler-backend-runtime-alloc-data) "")
       (if oob (compiler-backend-runtime-oob-data) ""))]))

(define (compiler-backend-runtime-alloc-functions) : String
  "    .globl tl_alloc
tl_alloc:
    addq $7, %rdi
    jc .L_tl_alloc_abort
    andq $-8, %rdi
    cmpq $0, %rdi
    jne .L_tl_alloc_size_ready
    movq $8, %rdi
.L_tl_alloc_size_ready:
    movq %rdi, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_alloc_abort
    ret
.L_tl_alloc_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_alloc_msg(%rip), %rsi
    movq $.L_tl_alloc_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")

(define (compiler-backend-runtime-oob-functions) : String
  "    .globl tl_oob_abort
tl_oob_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_oob_msg(%rip), %rsi
    movq $.L_tl_oob_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")

(define (compiler-backend-runtime-substring-functions) : String
  "    .globl tl_substring
tl_substring:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    addq %rsi, %rbx
    movq %rdx, %r12
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    movq $0, %rcx
.L_tl_substring_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_substring_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_substring_copy_loop
.L_tl_substring_copy_done:
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-concat-functions) : String
  "    .globl tl_string_concat
tl_string_concat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq %rcx, %r14
    movq %r12, %rdi
    addq %r14, %rdi
    call tl_alloc
    movq %rax, %r15
    movq $0, %rcx
.L_tl_string_concat_copy_a:
    cmpq %r12, %rcx
    jge .L_tl_string_concat_copy_a_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_string_concat_copy_a
.L_tl_string_concat_copy_a_done:
    movq $0, %rcx
.L_tl_string_concat_copy_b:
    cmpq %r14, %rcx
    jge .L_tl_string_concat_copy_b_done
    movzbl (%r13,%rcx), %edx
    movq %r12, %rax
    addq %rcx, %rax
    movb %dl, (%r15,%rax)
    incq %rcx
    jmp .L_tl_string_concat_copy_b
.L_tl_string_concat_copy_b_done:
    movq $16, %rdi
    call tl_alloc
    movq %r15, 0(%rax)
    movq %r12, %rdx
    addq %r14, %rdx
    movq %rdx, 8(%rax)
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-functions [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan alloc oob substring concat)
     (string-append
       (if alloc (compiler-backend-runtime-alloc-functions) "")
       (string-append
         (if oob (compiler-backend-runtime-oob-functions) "")
         (string-append
           (if substring (compiler-backend-runtime-substring-functions) "")
           (if concat (compiler-backend-runtime-concat-functions) ""))))]))

(define (compiler-backend-entry) : String
  "_start:\n    call main\n    movq %rax, %rdi\n    movq $60, %rax\n    syscall\n")

(define (compiler-backend-emit-program [program : CompilerIrProgram]) : ResultCompilerBackend
  (match (compiler-backend-runtime-plan program)
    [(OkBackendRuntimePlan plan)
     (match program
       [(IrProgram globals functions externs)
        (match (compiler-backend-emit-globals globals)
          [(OkCompilerBackend globals-asm)
           (match (compiler-backend-emit-functions functions functions externs plan)
             [(OkCompilerBackend functions-asm)
              (let ([strings : BackendStringList (compiler-backend-collect-program-strings program)]
                    [buf : TextBuf
                     (text-buf-append
                       (text-buf-append
                         (text-buf-append
                           (text-buf-append
                             (text-buf-append
                               (text-buf-append
                                 (text-buf-append
                                   (text-buf-append
                                     (text-buf-append (text-buf-empty) ".data\n")
                                     globals-asm)
                                   (compiler-backend-emit-string-rodata strings))
                                 (compiler-backend-runtime-data plan))
                               (compiler-backend-emit-externs externs plan))
                             ".text\n.globl _start\n")
                           functions-asm)
                         (compiler-backend-runtime-functions plan))
                       (compiler-backend-entry))])
                (OkCompilerBackend (text-buf-render buf)))]
             [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
    [(ErrBackendRuntimePlan message) (ErrCompilerBackend message)]))

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

(define (compiler-backend-runtime-helper-externs) : CompilerIrExternList
  (IrExternCons
    (IrExtern "tl_alloc" (AstTyI64))
    (IrExternCons
      (IrExtern "tl_oob_abort" (AstTyUnit))
      (IrExternCons
        (IrExtern "tl_substring" (AstTyI64))
        (IrExternCons
          (IrExtern "tl_string_concat" (AstTyI64))
          IrExternNil)))))

(define (compiler-backend-runtime-helper-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        3
        (IrBlockCons
          (IrBlock
            "entry"
            (IrInstrCons
              (IrInstrCall
                0
                "tl_alloc"
                (IrValueCons (IrValueI64 8) IrValueNil)
                (AstTyI64))
              (IrInstrCons
                (IrInstrCall
                  1
                  "tl_substring"
                  (IrValueCons
                    (IrValueI64 0)
                    (IrValueCons
                      (IrValueI64 0)
                      (IrValueCons (IrValueI64 0) IrValueNil)))
                  (AstTyI64))
                (IrInstrCons
                  (IrInstrCall
                    2
                    "tl_string_concat"
                    (IrValueCons
                      (IrValueI64 0)
                      (IrValueCons
                        (IrValueI64 0)
                        (IrValueCons
                          (IrValueI64 0)
                          (IrValueCons (IrValueI64 0) IrValueNil))))
                    (AstTyI64))
                  (IrInstrCons
                    (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                    IrInstrNil)))))
          IrBlockNil))
      IrFunctionNil)
    (compiler-backend-runtime-helper-externs)))

(define (compiler-backend-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-runtime-helper-program))
    [(OkCompilerBackend asm)
     (let ([base-labels : bool
            (backend-and4
              (compiler-backend-string-contains? asm ".globl tl_alloc\n")
              (compiler-backend-string-contains? asm "tl_alloc:\n")
              (compiler-backend-string-contains? asm ".globl tl_oob_abort\n")
              (compiler-backend-string-contains? asm "tl_oob_abort:\n"))]
           [string-labels : bool
            (backend-and4
              (compiler-backend-string-contains? asm ".globl tl_substring\n")
              (compiler-backend-string-contains? asm "tl_substring:\n")
              (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
              (compiler-backend-string-contains? asm "tl_string_concat:\n"))]
           [no-externs : bool
            (backend-and4
              (not (compiler-backend-string-contains? asm ".extern tl_alloc\n"))
              (not (compiler-backend-string-contains? asm ".extern tl_oob_abort\n"))
              (not (compiler-backend-string-contains? asm ".extern tl_substring\n"))
              (not (compiler-backend-string-contains? asm ".extern tl_string_concat\n")))])
       (and base-labels
            (and string-labels
                 (and no-externs
                      (compiler-backend-string-contains? asm "    call tl_alloc\n")))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-user-helper-name-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "tl_alloc"
        IrParamNil
        (AstTyI64)
        0
        (IrBlockCons
          (IrBlock
            "entry"
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (IrFunctionCons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          1
          (IrBlockCons
            (IrBlock
              "entry"
              (IrInstrCons
                (IrInstrCall 0 "tl_alloc" IrValueNil (AstTyI64))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-user-helper-name-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-user-helper-name-program))
    [(OkCompilerBackend asm)
     (and (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
          (and (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
               (not (compiler-backend-string-contains? asm ".L_tl_alloc_msg"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-runtime-coexist-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "tl_alloc"
        IrParamNil
        (AstTyI64)
        0
        (IrBlockCons
          (IrBlock
            "entry"
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (IrFunctionCons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          2
          (IrBlockCons
            (IrBlock
              "entry"
              (IrInstrCons
                (IrInstrCall 0 "tl_alloc" IrValueNil (AstTyI64))
                (IrInstrCons
                  (IrInstrCall
                    1
                    "tl_substring"
                    (IrValueCons
                      (IrValueI64 0)
                      (IrValueCons
                        (IrValueI64 0)
                        (IrValueCons (IrValueI64 0) IrValueNil)))
                    (AstTyI64))
                  (IrInstrCons
                    (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                    IrInstrNil))))
            IrBlockNil))
        IrFunctionNil))
    (IrExternCons (IrExtern "tl_substring" (AstTyI64)) IrExternNil)))

(define (compiler-backend-runtime-coexist-ok?) : bool
  (match (compiler-backend-emit-program (compiler-backend-runtime-coexist-program))
    [(OkCompilerBackend asm)
     (and (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
          (and (compiler-backend-string-contains? asm ".globl tl_alloc\n")
               (and (compiler-backend-string-contains? asm ".globl tl_substring\n")
                    (and (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
                         (and (compiler-backend-string-contains? asm "    call tl_substring\n")
                              (not (compiler-backend-string-contains? asm ".extern tl_substring\n")))))))]
    [(ErrCompilerBackend _) false]))

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

(define (compiler-backend-string-source) : String
  "(define greeting : String \"hi\")
(define (main) : String \"hi\")")

(define (compiler-backend-asm-ok? [asm : String]) : bool
  (and (compiler-backend-string-contains? asm ".data\n")
       (and (compiler-backend-string-contains? asm ".text\n")
            (and (compiler-backend-string-contains? asm ".globl _start\n")
                 (and (compiler-backend-string-contains? asm "_start:\n")
                      (and (compiler-backend-string-contains? asm "main:\n")
                           (and (compiler-backend-string-contains? asm "_tl_inc:\n")
                                (and (compiler-backend-string-contains? asm "_tl_answer:\n")
                                     (and (compiler-backend-string-contains? asm "    call _tl_inc\n")
                                          (and (compiler-backend-string-contains? asm "    setl %al\n")
                                               (and (compiler-backend-string-contains? asm "    setg %al\n")
                                                    (and (compiler-backend-string-contains? asm "    cmpq $0, %rax\n")
                                                         (and (compiler-backend-string-contains? asm "    jne .Lmain_while_body.1\n")
                                                              (compiler-backend-string-contains? asm "    jmp .Lmain_while_header.0\n"))))))))))))))

(define (compiler-backend-source-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-asm-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-string-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-source))
    [(OkCompilerBackend asm)
     (and (compiler-backend-string-contains? asm ".L_tl_str_data_6869:")
          (and (compiler-backend-string-contains? asm ".L_tl_str_6869:")
               (and (compiler-backend-string-contains? asm "    .string \"hi\"\n")
                    (and (compiler-backend-string-contains? asm "    .quad .L_tl_str_data_6869\n")
                         (and (compiler-backend-string-contains? asm "    .quad 2\n")
                              (and (compiler-backend-string-contains? asm "_tl_greeting:\n    .quad .L_tl_str_6869\n")
                                   (compiler-backend-string-contains? asm "    leaq .L_tl_str_6869(%rip), %rax\n")))))))]
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

(define (compiler-backend-instr-contains? [instr : CompilerIrInstr] [needle : String]) : bool
  (match (compiler-backend-emit-instr
           "_tl_test"
           IrBlockNil
           "entry"
           instr
           (BackendRuntimePlan false false false false)
           IrFunctionNil
           IrExternNil)
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-memory-op-ok?) : bool
  (and (compiler-backend-instr-contains?
         (IrInstrAddrOf 2 1)
         "    leaq -16(%rbp), %rax\n")
       (and (compiler-backend-instr-contains?
              (IrInstrGep 3 (IrValueVar 1) (IrValueI64 2) (AstTyI32))
              "    imulq $4, %rbx\n")
            (and (compiler-backend-instr-contains?
                   (IrInstrLoad 4 (IrValueVar 1) (AstTyU8))
                   "    movzbq (%r10), %rax\n")
                 (and (compiler-backend-instr-contains?
                        (IrInstrStorePtr (IrValueVar 1) (IrValueI64 7) (AstTyI32))
                        "    movl %eax, (%r10)\n")
                      (compiler-backend-instr-contains?
                        (IrInstrCast 6 (IrValueVar 5) (AstTyI8) (AstTyI64))
                        "    movsbq -48(%rbp), %rax\n"))))))

(define (compiler-backend-self-test) : i64
  (if (and (compiler-backend-source-ok? (compiler-backend-smoke-source))
           (and (compiler-backend-deterministic-ok? (compiler-backend-smoke-source))
                (and (compiler-backend-string-ok?)
                     (and (compiler-backend-memory-op-ok?)
                          (and (compiler-backend-error-ok? (compiler-backend-too-many-call-source)
                                                           "backend: too many call args")
                               (and (compiler-backend-runtime-helper-asm-ok?)
                                    (and (compiler-backend-user-helper-name-ok?)
                                         (compiler-backend-runtime-coexist-ok?))))))))
      42
      (begin
        (panic "backend: smoke output mismatch")
        0)))
