;; compiler_backend.tl - First selfhost CompilerIrProgram -> x86_64 .s emitter (#447).

(import "compiler_lower.tl")

(import "compiler_diagnostic.tl")

(import "compiler_regalloc.tl")

(import "text_buf.tl")

(defenum ResultBackendReg
  (OkBackendReg String)
  (ErrBackendReg String))

(defenum ResultBackendValue
  (OkBackendValue CompilerIrValue)
  (ErrBackendValue String))

(defenum ResultCompilerBackend
  (OkCompilerBackend String)
  (ErrCompilerBackend CompilerDiagnostic))

(defenum CompilerBackendRuntimePlan
  (BackendRuntimePlan bool bool bool bool bool bool bool bool))

;; Backend code-generation target (#646). Linux/System V and Windows x64 are

;; both modeled here; target-specific runtime helpers are emitted below.

(defenum CompilerBackendTarget
  (BackendTargetLinux)
  (BackendTargetWindows))

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

(define (backend-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (backend-and4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (and a (and b (and c d))))

(define (backend-and8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (and (backend-and4 a b c d) (backend-and4 e f g h)))

(define (compiler-backend-round-up-16 [n : i64]) : i64
  (if (= n 0)
    0
    (* (/ (+ n 15) 16) 16)))

(define (compiler-backend-frame-size [vars : i64]) : i64
  (compiler-backend-round-up-16 (* vars 8)))

(define (compiler-backend-slot [var-id : i64]) : String
  (string-append (int->string (- 0 (* 8 (+ var-id 1)))) "(%rbp)"))

(define (compiler-backend-frame-offset [offset : i64]) : String
  (string-append (int->string offset) "(%rbp)"))

(define (compiler-backend-plan-uses-reg?
  [assignments : CompilerRegAssignmentList]
  [reg : String]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) false]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment _ location)
          (match location
            [(CompilerRegRegister found)
              (if (string-eq found reg)
                true
                (compiler-backend-plan-uses-reg? rest reg))]
            [_ (compiler-backend-plan-uses-reg? rest reg)])])]))

(define (compiler-backend-plan-uses-callee-regs?
  [assignments : CompilerRegAssignmentList]) : bool
  (or
    (compiler-backend-plan-uses-reg? assignments "%r12")
    (or
      (compiler-backend-plan-uses-reg? assignments "%r13")
      (or
        (compiler-backend-plan-uses-reg? assignments "%r14")
        (compiler-backend-plan-uses-reg? assignments "%r15")))))

(define (compiler-backend-frame-slots
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : i64
  (if (compiler-backend-plan-uses-callee-regs? assignments)
    (+ vars 4)
    vars))

(define (compiler-backend-param-var? [params : CompilerIrParamList] [var : i64]) : bool
  (match params
    [(IrParamNil) false]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ param-var)
          (if (= var param-var)
            true
            (compiler-backend-param-var? rest var))])]))

(define (compiler-backend-drop-param-assignments
  [assignments : CompilerRegAssignmentList]
  [params : CompilerIrParamList]) : CompilerRegAssignmentList
  (match assignments
    [(CompilerRegAssignmentNil) CompilerRegAssignmentNil]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment var _)
          (let ([tail
              :
              CompilerRegAssignmentList
              (compiler-backend-drop-param-assignments rest params)])
            (if (compiler-backend-param-var? params var)
              tail
              (CompilerRegAssignmentCons item tail)))])]))

(define (compiler-backend-callee-save-slot [vars : i64] [idx : i64]) : String
  (compiler-backend-frame-offset (- 0 (* 8 (+ vars (+ idx 1))))))

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

(define (compiler-backend-emit-load-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (match (compiler-reg-assignment-lookup assignments var-id)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (if (string-eq home reg)
            ""
            (backend-cat5 "    movq " home ", " reg "\n"))]
        [(CompilerRegSpill offset)
          (backend-cat5
            "    movq "
            (compiler-backend-frame-offset offset)
            ", "
            reg
            "\n")])]
    [(CompilerRegNoLocation)
      (backend-cat5 "    movq " (compiler-backend-slot var-id) ", " reg "\n")]))

(define (compiler-backend-emit-store-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (match (compiler-reg-assignment-lookup assignments var-id)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (if (string-eq home reg)
            ""
            (backend-cat5 "    movq " reg ", " home "\n"))]
        [(CompilerRegSpill offset)
          (backend-cat5
            "    movq "
            reg
            ", "
            (compiler-backend-frame-offset offset)
            "\n")])]
    [(CompilerRegNoLocation) (compiler-backend-emit-store-var var-id reg)]))

(define (compiler-backend-emit-save-callee-reg
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [reg : String]
  [idx : i64]) : String
  (if (compiler-backend-plan-uses-reg? assignments reg)
    (backend-cat5
      "    movq "
      reg
      ", "
      (compiler-backend-callee-save-slot vars idx)
      "\n")
    ""))

(define (compiler-backend-emit-restore-callee-reg
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [reg : String]
  [idx : i64]) : String
  (if (compiler-backend-plan-uses-reg? assignments reg)
    (backend-cat5
      "    movq "
      (compiler-backend-callee-save-slot vars idx)
      ", "
      reg
      "\n")
    ""))

(define (compiler-backend-emit-save-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-save-callee-reg assignments vars "%r12" 0)
    (string-append
      (compiler-backend-emit-save-callee-reg assignments vars "%r13" 1)
      (string-append
        (compiler-backend-emit-save-callee-reg assignments vars "%r14" 2)
        (compiler-backend-emit-save-callee-reg assignments vars "%r15" 3)))))

(define (compiler-backend-emit-restore-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-restore-callee-reg assignments vars "%r15" 3)
    (string-append
      (compiler-backend-emit-restore-callee-reg assignments vars "%r14" 2)
      (string-append
        (compiler-backend-emit-restore-callee-reg assignments vars "%r13" 1)
        (compiler-backend-emit-restore-callee-reg assignments vars "%r12" 0)))))

(define (compiler-backend-char-code [c : char]) : i64
  (cast c : i64))

(define (compiler-backend-symbol-char [text : String] [idx : i64] [k : i64]) : String
  (if (or
    (and (>= k 65) (<= k 90))
    (or (and (>= k 97) (<= k 122)) (or (and (>= k 48) (<= k 57)) (= k 95))))
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
  (let ([i : i64 0] [n : i64 (string-length name)] [out : String ""])
    (begin
      (while (< i n)
        (let ([k : i64 (compiler-backend-char-code-at name i)])
          (begin
            (set!
              out
              (string-append out (compiler-backend-symbol-char name i k)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-user-symbol [name : String]) : String
  (if (string-eq name "main")
    "main"
    (string-append "_tl_" (compiler-backend-asm-safe-symbol name))))

(define (compiler-backend-call-symbol
  [name : String]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : String
  (if (and
    (compiler-backend-plan-provides? plan name)
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
  (string-append
    (compiler-backend-hex-digit (/ n 16))
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
  (string-append
    "\\"
    (string-append
      (compiler-backend-octal-digit (/ n 64))
      (string-append
        (compiler-backend-octal-digit (% (/ n 8) 8))
        (compiler-backend-octal-digit (% n 8))))))

(define (compiler-backend-escape-string-byte
  [text : String]
  [idx : i64]
  [k : i64]) : String
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
  (let ([i : i64 0] [n : i64 (string-length text)] [out : String ""])
    (begin
      (while (< i n)
        (let ([k : i64 (compiler-backend-char-code-at text i)])
          (begin
            (set!
              out
              (string-append out (compiler-backend-escape-string-byte text i k)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-quoted-gas-string [text : String]) : String
  (string-append
    "\""
    (string-append (compiler-backend-escape-string text) "\"")))

(define (compiler-backend-string-label-suffix [text : String]) : String
  (let ([i : i64 0] [n : i64 (string-length text)] [out : String ""])
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (string-append
              out
              (compiler-backend-hex-byte (compiler-backend-char-code-at text i))))
          (set! i (+ i 1))))
      (if (= n 0)
        "empty"
        out))))

(define (compiler-backend-string-data-label [text : String]) : String
  (string-append ".L_tl_str_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-string-fat-label [text : String]) : String
  (string-append ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-emit-load-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (match value
    [(IrValueVar id)
      (OkCompilerBackend
        (compiler-backend-emit-load-var-with-plan assignments id reg))]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (backend-cat5
          "    movq "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueI64 n)
      (OkCompilerBackend
        (backend-cat5 "    movq $" (int->string n) ", " reg "\n"))]
    [(IrValueBool b)
      (if b
        (OkCompilerBackend (backend-cat5 "    movq $" "1" ", " reg "\n"))
        (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n")))]
    [(IrValueChar c)
      (OkCompilerBackend
        (backend-cat5
          "    movq $"
          (int->string (compiler-backend-char-code c))
          ", "
          reg
          "\n"))]
    [(IrValueUnit)
      (OkCompilerBackend (backend-cat5 "    movq $" "0" ", " reg "\n"))]
    [(IrValueF64 _)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: f64 values are not supported yet"))]
    [(IrValueString text)
      (OkCompilerBackend
        (backend-cat5
          "    leaq "
          (compiler-backend-string-fat-label text)
          "(%rip), "
          reg
          "\n"))]))

(define (compiler-backend-emit-load-value
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (compiler-backend-emit-load-value-with-plan
    CompilerRegAssignmentNil
    value
    reg))

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

(define (compiler-backend-reg-part [reg : String] [size : i64]) : String
  (if (= size 8)
    reg
    (if (string-eq reg "%r12")
      (if (= size 4)
        "%r12d"
        (if (= size 2)
          "%r12w"
          "%r12b"))
      (if (string-eq reg "%r13")
        (if (= size 4)
          "%r13d"
          (if (= size 2)
            "%r13w"
            "%r13b"))
        (if (string-eq reg "%r14")
          (if (= size 4)
            "%r14d"
            (if (= size 2)
              "%r14w"
              "%r14b"))
          (if (= size 4)
            "%r15d"
            (if (= size 2)
              "%r15w"
              "%r15b")))))))

(define (compiler-backend-emit-load-register [reg : String] [ty : AstType]) : String
  (let ([size : i64 (compiler-backend-type-size ty)])
    (if (= size 8)
      (backend-cat3 "    movq " reg ", %rax\n")
      (if (= size 4)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3
            "    movslq "
            (compiler-backend-reg-part reg size)
            ", %rax\n")
          (backend-cat3
            "    movl "
            (compiler-backend-reg-part reg size)
            ", %eax\n"))
        (if (= size 2)
          (if (compiler-backend-type-signed? ty)
            (backend-cat3
              "    movswq "
              (compiler-backend-reg-part reg size)
              ", %rax\n")
            (backend-cat3
              "    movzwq "
              (compiler-backend-reg-part reg size)
              ", %rax\n"))
          (if (= size 1)
            (if (compiler-backend-type-signed? ty)
              (backend-cat3
                "    movsbq "
                (compiler-backend-reg-part reg size)
                ", %rax\n")
              (backend-cat3
                "    movzbq "
                (compiler-backend-reg-part reg size)
                ", %rax\n"))
            ""))))))

(define (compiler-backend-emit-store-rax-to-memory
  [addr : String]
  [ty : AstType]) : String
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

(define (compiler-backend-emit-load-typed-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match value
    [(IrValueVar id)
      (match (compiler-reg-assignment-lookup assignments id)
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegRegister home)
              (OkCompilerBackend (compiler-backend-emit-load-register home ty))]
            [(CompilerRegSpill offset)
              (OkCompilerBackend
                (compiler-backend-emit-load-memory
                  (compiler-backend-frame-offset offset)
                  ty))])]
        [(CompilerRegNoLocation)
          (OkCompilerBackend
            (compiler-backend-emit-load-memory (compiler-backend-slot id) ty))])]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (compiler-backend-emit-load-memory
          (backend-cat3 (compiler-backend-user-symbol name) "(%rip)" "")
          ty))]
    [_ (compiler-backend-emit-load-value-with-plan assignments value "%rax")]))

(define (compiler-backend-emit-load-typed-value
  [value : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (compiler-backend-emit-load-typed-value-with-plan
    CompilerRegAssignmentNil
    value
    ty))

(define (compiler-backend-unsigned-rel-ty? [ty : AstType]) : bool
  (match ty
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [_ false]))

(define (compiler-backend-binop-asm [op : CompilerIrBinOp] [ty : AstType]) : String
  (match op
    [(IrBinAdd) "    addq %rbx, %rax\n"]
    [(IrBinSub) "    subq %rbx, %rax\n"]
    [(IrBinMul) "    imulq %rbx, %rax\n"]
    [(IrBinDiv) "    cqto\n    idivq %rbx\n"]
    [(IrBinMod) "    cqto\n    idivq %rbx\n    movq %rdx, %rax\n"]
    [(IrBinEq) "    cmpq %rbx, %rax\n    sete %al\n    movzbq %al, %rax\n"]
    [(IrBinNe) "    cmpq %rbx, %rax\n    setne %al\n    movzbq %al, %rax\n"]
    [(IrBinLt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "    cmpq %rbx, %rax\n    setb %al\n    movzbq %al, %rax\n"
        "    cmpq %rbx, %rax\n    setl %al\n    movzbq %al, %rax\n")]
    [(IrBinLe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "    cmpq %rbx, %rax\n    setbe %al\n    movzbq %al, %rax\n"
        "    cmpq %rbx, %rax\n    setle %al\n    movzbq %al, %rax\n")]
    [(IrBinGt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "    cmpq %rbx, %rax\n    seta %al\n    movzbq %al, %rax\n"
        "    cmpq %rbx, %rax\n    setg %al\n    movzbq %al, %rax\n")]
    [(IrBinGe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "    cmpq %rbx, %rax\n    setae %al\n    movzbq %al, %rax\n"
        "    cmpq %rbx, %rax\n    setge %al\n    movzbq %al, %rax\n")]
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

(define (compiler-backend-emit-binop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments lhs "%rax")
    [(OkCompilerBackend lhs-asm)
      (match (compiler-backend-emit-load-value-with-plan assignments rhs "%rbx")
        [(OkCompilerBackend rhs-asm)
          (OkCompilerBackend
            (string-append
              lhs-asm
              (string-append
                rhs-asm
                (string-append
                  (compiler-backend-binop-asm op ty)
                  (compiler-backend-emit-store-var-with-plan
                    assignments
                    dst
                    "%rax")))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-unop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrUnOp]
  [src : CompilerIrValue]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments src "%rax")
    [(OkCompilerBackend src-asm)
      (OkCompilerBackend
        (string-append
          src-asm
          (string-append
            (compiler-backend-unop-asm op)
            (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-addr-of
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : i64]) : ResultCompilerBackend
  (OkCompilerBackend
    (string-append
      (backend-cat5 "    leaq " (compiler-backend-slot src) ", " "%rax" "\n")
      (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))

(define (compiler-backend-emit-gep
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments base "%rax")
    [(OkCompilerBackend base-asm)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        offset
        "%rbx")
        [(OkCompilerBackend offset-asm)
          (let ([scale : i64 (compiler-backend-type-size elem-ty)])
            (OkCompilerBackend
              (string-append
                base-asm
                (string-append
                  offset-asm
                  (string-append
                    (if (= scale 1)
                      ""
                      (backend-cat5
                        "    imulq $"
                        (int->string scale)
                        ", "
                        "%rbx"
                        "\n"))
                    (string-append
                      "    addq %rbx, %rax\n"
                      (compiler-backend-emit-store-var-with-plan
                        assignments
                        dst
                        "%rax")))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-load-instr
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments src "%r10")
    [(OkCompilerBackend ptr-asm)
      (OkCompilerBackend
        (string-append
          ptr-asm
          (string-append
            (compiler-backend-emit-load-memory "(%r10)" ty)
            (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-store-ptr
  [assignments : CompilerRegAssignmentList]
  [dst : CompilerIrValue]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments dst "%r10")
    [(OkCompilerBackend ptr-asm)
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        src
        ty)
        [(OkCompilerBackend src-asm)
          (OkCompilerBackend
            (string-append
              ptr-asm
              (string-append
                src-asm
                (compiler-backend-emit-store-rax-to-memory "(%r10)" ty))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-cast
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-typed-value-with-plan
    assignments
    src
    from-ty)
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-ir-value-list-count [args : CompilerIrValueList]) : i64
  (match args
    [(IrValueNil) 0]
    [(IrValueCons _ rest) (+ 1 (compiler-backend-ir-value-list-count rest))]))

(define (compiler-backend-call-register-count [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 6]
    [(BackendTargetWindows) 4]))

(define (compiler-backend-call-arg-space
  [target : CompilerBackendTarget]
  [arg-count : i64]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows)
      (let ([reg-count : i64 (compiler-backend-call-register-count target)])
        (let ([stack-count
            :
            i64
            (if (> arg-count reg-count)
              (- arg-count reg-count)
              0)])
          (compiler-backend-round-up-16
            (+
              (compiler-backend-outgoing-shadow-space target)
              (* stack-count 8)))))]))

(define (compiler-backend-emit-call-space-sub [space : i64]) : String
  (if (= space 0)
    ""
    (backend-cat4 "    subq $" (int->string space) ", %rsp\n" "")))

(define (compiler-backend-emit-call-space-add [space : i64]) : String
  (if (= space 0)
    ""
    (backend-cat4 "    addq $" (int->string space) ", %rsp\n" "")))

(define (compiler-backend-stack-call-arg?
  [target : CompilerBackendTarget]
  [idx : i64]) : bool
  (match target
    [(BackendTargetLinux) false]
    [(BackendTargetWindows)
      (>= idx (compiler-backend-call-register-count target))]))

(define (compiler-backend-outgoing-stack-arg-offset
  [target : CompilerBackendTarget]
  [idx : i64]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows)
      (+
        (compiler-backend-outgoing-shadow-space target)
        (* (- idx (compiler-backend-call-register-count target)) 8))]))

(define (compiler-backend-emit-call-args
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrValueList]
  [idx : i64]) : ResultCompilerBackend
  (match args
    [(IrValueNil) (OkCompilerBackend "")]
    [(IrValueCons value rest)
      (if (compiler-backend-stack-call-arg? target idx)
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          value
          "%rax")
          [(OkCompilerBackend head)
            (match (compiler-backend-emit-call-args
              target
              assignments
              rest
              (+ idx 1))
              [(OkCompilerBackend tail)
                (OkCompilerBackend
                  (backend-cat5
                    head
                    "    movq %rax, "
                    (int->string
                      (compiler-backend-outgoing-stack-arg-offset target idx))
                    "(%rsp)\n"
                    tail))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])
        (match (compiler-backend-target-arg-reg target idx)
          [(OkBackendReg reg)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              value
              reg)
              [(OkCompilerBackend head)
                (match (compiler-backend-emit-call-args
                  target
                  assignments
                  rest
                  (+ idx 1))
                  [(OkCompilerBackend tail)
                    (OkCompilerBackend (string-append head tail))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrBackendReg message)
            (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))]))

(define (compiler-backend-phi-input-value
  [inputs : CompilerIrPhiInputList]
  [from-label : String]) : ResultBackendValue
  (match inputs
    [(IrPhiInputNil)
      (ErrBackendValue
        (string-append "backend: missing phi input from " from-label))]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value label)
          (if (string-eq label from-label)
            (OkBackendValue value)
            (compiler-backend-phi-input-value rest from-label))])]))

(define (compiler-backend-emit-phi-copy
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [inputs : CompilerIrPhiInputList]
  [from-label : String]) : ResultCompilerBackend
  (match (compiler-backend-phi-input-value inputs from-label)
    [(OkBackendValue value)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrBackendValue message)
      (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))

(define (compiler-backend-emit-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrList]
  [from-label : String]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi dst inputs _)
          (match (compiler-backend-emit-phi-copy
            assignments
            dst
            inputs
            from-label)
            [(OkCompilerBackend asm)
              (match (compiler-backend-emit-leading-phi-copies
                assignments
                rest
                from-label)
                [(OkCompilerBackend tail)
                  (OkCompilerBackend (string-append asm tail))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [_ (OkCompilerBackend "")])]))

(define (compiler-backend-emit-phi-edge-copies
  [assignments : CompilerRegAssignmentList]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          (string-append "backend: unknown block " target-label)))]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label target-label)
            (compiler-backend-emit-leading-phi-copies
              assignments
              instrs
              from-label)
            (compiler-backend-emit-phi-edge-copies
              assignments
              rest
              target-label
              from-label))])]))

(define (compiler-backend-emit-return
  [value : CompilerIrMaybeValue]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : ResultCompilerBackend
  (match value
    [(IrNoValue)
      (OkCompilerBackend
        (string-append
          "    movq $0, %rax\n"
          (string-append
            (compiler-backend-emit-restore-callee-regs assignments vars)
            "    movq %rbp, %rsp\n    popq %rbp\n    ret\n")))]
    [(IrSomeValue v)
      (match (compiler-backend-emit-load-value-with-plan assignments v "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (string-append
                (compiler-backend-emit-restore-callee-regs assignments vars)
                "    movq %rbp, %rsp\n    popq %rbp\n    ret\n")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-instr
  [target : CompilerBackendTarget]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [instr : CompilerIrInstr]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match instr
    [(IrInstrMov dst src _)
      (match (compiler-backend-emit-load-value-with-plan assignments src "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrAlloc _ _) (OkCompilerBackend "")]
    [(IrInstrAddrOf dst src)
      (compiler-backend-emit-addr-of assignments dst src)]
    [(IrInstrGep dst base offset elem-ty)
      (compiler-backend-emit-gep assignments dst base offset elem-ty)]
    [(IrInstrLoad dst src ty)
      (compiler-backend-emit-load-instr assignments dst src ty)]
    [(IrInstrStorePtr dst src ty)
      (compiler-backend-emit-store-ptr assignments dst src ty)]
    [(IrInstrCast dst src from-ty to-ty)
      (compiler-backend-emit-cast assignments dst src from-ty to-ty)]
    [(IrInstrBinOp dst op lhs rhs ty)
      (compiler-backend-emit-binop assignments dst op lhs rhs ty)]
    [(IrInstrUnOp dst op src _)
      (compiler-backend-emit-unop assignments dst op src)]
    [(IrInstrCall dst name args _)
      (let ([call-space
          :
          i64
          (compiler-backend-call-arg-space
            target
            (compiler-backend-ir-value-list-count args))])
        (match (compiler-backend-emit-call-args target assignments args 0)
          [(OkCompilerBackend args-asm)
            (OkCompilerBackend
              (string-append
                (compiler-backend-emit-call-space-sub call-space)
                (string-append
                  args-asm
                  (backend-cat5
                    "    call "
                    (compiler-backend-call-symbol name plan functions externs)
                    "\n"
                    (string-append
                      (compiler-backend-emit-call-space-add call-space)
                      (compiler-backend-emit-store-var-with-plan
                        assignments
                        dst
                        "%rax"))
                    ""))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [(IrInstrStore name value _)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (backend-cat4
                "    movq %rax, "
                (compiler-backend-user-symbol name)
                "(%rip)\n"
                "")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrJump target)
      (match (compiler-backend-emit-phi-edge-copies
        assignments
        blocks
        target
        current-label)
        [(OkCompilerBackend copies)
          (OkCompilerBackend
            (string-append
              copies
              (backend-cat4
                "    jmp "
                (compiler-backend-asm-label function target)
                "\n"
                "")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrBranch cond true-label false-label)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        cond
        "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (string-append
                "    cmpq $0, %rax\n"
                (backend-cat5
                  "    jne "
                  (compiler-backend-asm-label function true-label)
                  "\n    jmp "
                  (compiler-backend-asm-label function false-label)
                  "\n"))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrInstrReturn value)
      (compiler-backend-emit-return value assignments vars)]
    [(IrInstrPhi _ _ _) (OkCompilerBackend "")]))

(define (compiler-backend-emit-instrs
  [target : CompilerBackendTarget]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
      (match (compiler-backend-emit-instr
        target
        function
        blocks
        current-label
        instr
        assignments
        vars
        plan
        functions
        externs)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-instrs
            target
            function
            blocks
            current-label
            rest
            assignments
            vars
            plan
            functions
            externs)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-block
  [target : CompilerBackendTarget]
  [function : String]
  [blocks : CompilerIrBlockList]
  [block : CompilerIrBlock]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match block
    [(IrBlock label instrs)
      (match (compiler-backend-emit-instrs
        target
        function
        blocks
        label
        instrs
        assignments
        vars
        plan
        functions
        externs)
        [(OkCompilerBackend body)
          (OkCompilerBackend
            (backend-cat4
              (compiler-backend-asm-label function label)
              ":\n"
              body
              ""))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-blocks
  [target : CompilerBackendTarget]
  [function : String]
  [all-blocks : CompilerIrBlockList]
  [blocks : CompilerIrBlockList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
      (match (compiler-backend-emit-block
        target
        function
        all-blocks
        block
        assignments
        vars
        plan
        functions
        externs)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-blocks
            target
            function
            all-blocks
            rest
            assignments
            vars
            plan
            functions
            externs)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-param-spills
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [params : CompilerIrParamList]
  [idx : i64]) : ResultCompilerBackend
  (match params
    [(IrParamNil) (OkCompilerBackend "")]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var-id)
          (if (compiler-backend-stack-call-arg? target idx)
            (match (compiler-backend-emit-param-spills
              target
              assignments
              rest
              (+ idx 1))
              [(OkCompilerBackend tail)
                (OkCompilerBackend
                  (string-append
                    (backend-cat4
                      "    movq "
                      (int->string
                        (+
                          16
                          (compiler-backend-outgoing-stack-arg-offset
                            target
                            idx)))
                      "(%rbp), %rax\n"
                      "")
                    (string-append
                      (compiler-backend-emit-store-var-with-plan
                        assignments
                        var-id
                        "%rax")
                      tail)))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])
            (match (compiler-backend-target-arg-reg target idx)
              [(OkBackendReg reg)
                (match (compiler-backend-emit-param-spills
                  target
                  assignments
                  rest
                  (+ idx 1))
                  [(OkCompilerBackend tail)
                    (OkCompilerBackend
                      (string-append
                        (compiler-backend-emit-store-var-with-plan
                          assignments
                          var-id
                          reg)
                        tail))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrBackendReg _)
                (ErrCompilerBackend
                  (compiler-diagnostic-at-start "" "backend: too many params"))]))])]))

(define (compiler-backend-emit-function
  [target : CompilerBackendTarget]
  [func : CompilerIrFunction]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : ResultCompilerBackend
  (match func
    [(IrFunction name params _ vars blocks)
      (let ([reg-plan : CompilerRegPlan (compiler-reg-plan-function func)])
        (let ([raw-assignments
            :
            CompilerRegAssignmentList
            (compiler-reg-plan-assignments reg-plan)])
          (let ([assignments
              :
              CompilerRegAssignmentList
              (compiler-backend-drop-param-assignments raw-assignments params)])
            (match (compiler-backend-emit-param-spills
              target
              assignments
              params
              0)
              [(OkCompilerBackend spills)
                (let ([symbol : String (compiler-backend-user-symbol name)])
                  (match (compiler-backend-emit-blocks
                    target
                    symbol
                    blocks
                    blocks
                    assignments
                    vars
                    plan
                    functions
                    externs)
                    [(OkCompilerBackend body)
                      (let ([frame
                          :
                          i64
                          (compiler-backend-frame-size
                            (compiler-backend-frame-slots vars assignments))])
                        (OkCompilerBackend
                          (backend-cat5
                            ".globl "
                            symbol
                            "\n"
                            (backend-cat5
                              symbol
                              ":\n    pushq %rbp\n    movq %rsp, %rbp\n"
                              (compiler-backend-emit-stack-sub frame)
                              (string-append
                                (compiler-backend-emit-save-callee-regs
                                  assignments
                                  vars)
                                (string-append spills body))
                              "\n")
                            "")))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))]))

(define (compiler-backend-emit-functions
  [target : CompilerBackendTarget]
  [functions : CompilerIrFunctionList]
  [all-functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend "")]
    [(IrFunctionCons func rest)
      (match (compiler-backend-emit-function
        target
        func
        all-functions
        externs
        plan)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-functions
            target
            rest
            all-functions
            externs
            plan)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-string-list-contains?
  [strings : BackendStringList]
  [text : String]) : bool
  (match strings
    [(BackendStringNil) false]
    [(BackendStringCons head rest)
      (if (string-eq head text)
        true
        (compiler-backend-string-list-contains? rest text))]))

(define (compiler-backend-string-list-append
  [strings : BackendStringList]
  [text : String]) : BackendStringList
  (match strings
    [(BackendStringNil) (BackendStringCons text BackendStringNil)]
    [(BackendStringCons head rest)
      (BackendStringCons head (compiler-backend-string-list-append rest text))]))

(define (compiler-backend-string-list-add
  [strings : BackendStringList]
  [text : String]) : BackendStringList
  (if (compiler-backend-string-list-contains? strings text)
    strings
    (compiler-backend-string-list-append strings text)))

(define (compiler-backend-collect-value-string
  [strings : BackendStringList]
  [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueString text) (compiler-backend-string-list-add strings text)]
    [_ strings]))

(define (compiler-backend-collect-value-list-strings
  [strings : BackendStringList]
  [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) strings]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-strings
        (compiler-backend-collect-value-string strings value)
        rest)]))

(define (compiler-backend-collect-phi-strings
  [strings : BackendStringList]
  [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) strings]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (compiler-backend-collect-phi-strings
            (compiler-backend-collect-value-string strings value)
            rest)])]))

(define (compiler-backend-collect-instr-strings
  [strings : BackendStringList]
  [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-value-list-strings strings args)]
    [(IrInstrStore _ value _)
      (compiler-backend-collect-value-string strings value)]
    [(IrInstrBranch cond _ _)
      (compiler-backend-collect-value-string strings cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) strings]
        [(IrSomeValue value)
          (compiler-backend-collect-value-string strings value)])]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-collect-phi-strings strings inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings base)
        offset)]
    [(IrInstrLoad _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings dst)
        src)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-collect-value-string strings src)]
    [_ strings]))

(define (compiler-backend-collect-instr-list-strings
  [strings : BackendStringList]
  [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) strings]
    [(IrInstrCons instr rest)
      (compiler-backend-collect-instr-list-strings
        (compiler-backend-collect-instr-strings strings instr)
        rest)]))

(define (compiler-backend-collect-block-strings
  [strings : BackendStringList]
  [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) strings]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-collect-block-strings
            (compiler-backend-collect-instr-list-strings strings instrs)
            rest)])]))

(define (compiler-backend-collect-function-strings
  [strings : BackendStringList]
  [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) strings]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-backend-collect-function-strings
            (compiler-backend-collect-block-strings strings blocks)
            rest)])]))

(define (compiler-backend-collect-global-strings
  [strings : BackendStringList]
  [globals : CompilerIrGlobalList]) : BackendStringList
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
      (string-append
        (compiler-backend-emit-string-entry text)
        (compiler-backend-emit-string-entries rest))]))

(define (compiler-backend-emit-string-rodata [strings : BackendStringList]) : String
  (match strings
    [(BackendStringNil) ""]
    [_
      (string-append
        "    .section .rodata\n"
        (string-append (compiler-backend-emit-string-entries strings) "\n"))]))

(define (compiler-backend-global-value-asm [value : CompilerIrValue]) : ResultCompilerBackend
  (match value
    [(IrValueI64 n)
      (OkCompilerBackend (backend-cat3 "    .quad " (int->string n) "\n"))]
    [(IrValueBool b)
      (if b
        (OkCompilerBackend "    .quad 1\n")
        (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueChar c)
      (OkCompilerBackend
        (backend-cat3
          "    .quad "
          (int->string (compiler-backend-char-code c))
          "\n"))]
    [(IrValueUnit) (OkCompilerBackend "    .quad 0\n")]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (backend-cat3 "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueString text)
      (OkCompilerBackend
        (backend-cat3
          "    .quad "
          (compiler-backend-string-fat-label text)
          "\n"))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: unsupported global initializer"))]))

(define (compiler-backend-emit-global [global : CompilerIrGlobal]) : ResultCompilerBackend
  (match global
    [(IrGlobal name _ value)
      (match (compiler-backend-global-value-asm value)
        [(OkCompilerBackend value-asm)
          (let ([symbol : String (compiler-backend-user-symbol name)])
            (OkCompilerBackend
              (backend-cat5
                ".globl "
                symbol
                "\n"
                (backend-cat3 symbol ":\n" value-asm)
                "")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-globals [globals : CompilerIrGlobalList]) : ResultCompilerBackend
  (match globals
    [(IrGlobalNil) (OkCompilerBackend "")]
    [(IrGlobalCons global rest)
      (match (compiler-backend-emit-global global)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-globals rest)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-function-list-defines?
  [functions : CompilerIrFunctionList]
  [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction func-name _ _ _ _)
          (if (string-eq func-name name)
            true
            (compiler-backend-function-list-defines? rest name))])]))

(define (compiler-backend-extern-list-references?
  [externs : CompilerIrExternList]
  [name : String]) : bool
  (match externs
    [(IrExternNil) false]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _)
          (if (string-eq extern-name name)
            true
            (compiler-backend-extern-list-references? rest name))])]))

(define (compiler-backend-instr-calls?
  [instr : CompilerIrInstr]
  [name : String]) : bool
  (match instr
    [(IrInstrCall _ call-name _ _) (string-eq call-name name)]
    [_ false]))

(define (compiler-backend-instr-list-calls?
  [instrs : CompilerIrInstrList]
  [name : String]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (compiler-backend-instr-calls? instr name)
        true
        (compiler-backend-instr-list-calls? rest name))]))

(define (compiler-backend-block-list-calls?
  [blocks : CompilerIrBlockList]
  [name : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instr-list-calls? instrs name)
            true
            (compiler-backend-block-list-calls? rest name))])]))

(define (compiler-backend-function-list-calls?
  [functions : CompilerIrFunctionList]
  [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (if (compiler-backend-block-list-calls? blocks name)
            true
            (compiler-backend-function-list-calls? rest name))])]))

(define (compiler-backend-plan-provides?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        read-line
        read-bytes
        stdin-eof
        flush-stdout)
      (if (string-eq name "tl_alloc")
        alloc
        (if (string-eq name "tl_oob_abort")
          oob
          (if (string-eq name "tl_substring")
            substring
            (if (string-eq name "tl_string_concat")
              concat
              (if (string-eq name ".L_tl_read_stdin_line")
                read-line
                (if (string-eq name ".L_tl_read_stdin_bytes")
                  read-bytes
                  (if (string-eq name ".L_tl_stdin_eof")
                    stdin-eof
                    (if (string-eq name ".L_tl_flush_stdout")
                      flush-stdout
                      false))))))))]))

(define (compiler-backend-runtime-plan-for
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultBackendRuntimePlan
  (let ([defines-alloc
      :
      bool
      (compiler-backend-function-list-defines? functions "tl_alloc")]
    [defines-oob
      :
      bool
      (compiler-backend-function-list-defines? functions "tl_oob_abort")]
    [defines-substring
      :
      bool
      (compiler-backend-function-list-defines? functions "tl_substring")]
    [defines-concat
      :
      bool
      (compiler-backend-function-list-defines? functions "tl_string_concat")]
    [extern-alloc
      :
      bool
      (compiler-backend-extern-list-references? externs "tl_alloc")]
    [extern-oob
      :
      bool
      (compiler-backend-extern-list-references? externs "tl_oob_abort")]
    [extern-substring
      :
      bool
      (compiler-backend-extern-list-references? externs "tl_substring")]
    [extern-concat
      :
      bool
      (compiler-backend-extern-list-references? externs "tl_string_concat")]
    [extern-read-line
      :
      bool
      (compiler-backend-extern-list-references? externs ".L_tl_read_stdin_line")]
    [extern-read-bytes
      :
      bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_read_stdin_bytes")]
    [extern-stdin-eof
      :
      bool
      (compiler-backend-extern-list-references? externs ".L_tl_stdin_eof")]
    [extern-flush-stdout
      :
      bool
      (compiler-backend-extern-list-references? externs ".L_tl_flush_stdout")]
    [calls-alloc
      :
      bool
      (compiler-backend-function-list-calls? functions "tl_alloc")]
    [calls-oob
      :
      bool
      (compiler-backend-function-list-calls? functions "tl_oob_abort")]
    [calls-substring
      :
      bool
      (compiler-backend-function-list-calls? functions "tl_substring")]
    [calls-concat
      :
      bool
      (compiler-backend-function-list-calls? functions "tl_string_concat")]
    [calls-read-line
      :
      bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_stdin_line")]
    [calls-read-bytes
      :
      bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_stdin_bytes")]
    [calls-stdin-eof
      :
      bool
      (compiler-backend-function-list-calls? functions ".L_tl_stdin_eof")]
    [calls-flush-stdout
      :
      bool
      (compiler-backend-function-list-calls? functions ".L_tl_flush_stdout")])
    (let ([needs-oob : bool (and (not defines-oob) (or extern-oob calls-oob))]
      [needs-substring
        :
        bool
        (and (not defines-substring) (or extern-substring calls-substring))]
      [needs-concat
        :
        bool
        (and (not defines-concat) (or extern-concat calls-concat))]
      [needs-read-line : bool (or extern-read-line calls-read-line)]
      [needs-read-bytes : bool (or extern-read-bytes calls-read-bytes)]
      [needs-stdin-eof : bool (or extern-stdin-eof calls-stdin-eof)]
      [needs-flush-stdout : bool (or extern-flush-stdout calls-flush-stdout)]
      [direct-alloc
        :
        bool
        (and (not defines-alloc) (or extern-alloc calls-alloc))])
      (let ([needs-alloc
          :
          bool
          (or
            direct-alloc
            (or
              needs-substring
              (or needs-concat (or needs-read-line needs-read-bytes))))])
        (OkBackendRuntimePlan
          (BackendRuntimePlan
            needs-alloc
            needs-oob
            needs-substring
            needs-concat
            needs-read-line
            needs-read-bytes
            needs-stdin-eof
            needs-flush-stdout))))))

(define (compiler-backend-runtime-plan [program : CompilerIrProgram]) : ResultBackendRuntimePlan
  (match program
    [(IrProgram _ functions externs)
      (compiler-backend-runtime-plan-for functions externs)]))

(define (compiler-backend-emit-externs
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : String
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

(define (compiler-backend-runtime-stdio-data
  [read-line : bool]
  [read-bytes : bool]
  [stdin-eof : bool]) : String
  (if (or read-line (or read-bytes stdin-eof))
    (string-append
      "    .data
    .balign 8
.L_tl_stdin_eof_flag:
    .quad 0

"
      (if (or read-line read-bytes)
        "    .section .rodata
.L_tl_stdin_error_msg:
    .ascii \"tl: stdin failed\\n\"
    .set .L_tl_stdin_error_msg_len, . - .L_tl_stdin_error_msg

"
        ""))
    ""))

(define (compiler-backend-runtime-data [plan : CompilerBackendRuntimePlan]) : String
  (compiler-backend-runtime-data-for-target (BackendTargetLinux) plan))

(define (compiler-backend-runtime-flush-stdout-data
  [target : CompilerBackendTarget]
  [flush-stdout : bool]) : String
  (if (and (compiler-backend-target-windows? target) flush-stdout)
    "    .section .rodata
.L_tl_flush_stdout_error_msg:
    .ascii \"tl: flush-stdout failed\\n\"
    .set .L_tl_flush_stdout_error_msg_len, . - .L_tl_flush_stdout_error_msg

"
    ""))

(define (compiler-backend-runtime-data-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        _
        _
        read-line
        read-bytes
        stdin-eof
        flush-stdout)
      (string-append
        (if alloc
          (compiler-backend-runtime-alloc-data)
          "")
        (string-append
          (if oob
            (compiler-backend-runtime-oob-data)
            "")
          (string-append
            (compiler-backend-runtime-stdio-data read-line read-bytes stdin-eof)
            (compiler-backend-runtime-flush-stdout-data target flush-stdout))))]))

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

(define (compiler-backend-runtime-windows-alloc-functions) : String
  "    .globl tl_alloc
tl_alloc:
    push %rbp
    mov %rsp, %rbp
    testq %rcx, %rcx
    jg .L_tl_alloc_win_size_ready
    movq $1, %rcx
.L_tl_alloc_win_size_ready:
    sub $32, %rsp
    call malloc
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_alloc_abort
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_abort:
    movq $2, %rcx
    leaq .L_tl_alloc_msg(%rip), %rdx
    movq $.L_tl_alloc_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit

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

(define (compiler-backend-runtime-windows-fixed-abort-functions
  [symbol : String]
  [msg-label : String]
  [len-label : String]
  [status : i64]) : String
  (backend-cat5
    "    .globl "
    symbol
    "\n"
    (backend-cat4
      symbol
      ":\n    push %rbp\n    mov %rsp, %rbp\n    movq $2, %rcx\n    leaq "
      msg-label
      "(%rip), %rdx\n")
    (backend-cat5
      "    movq $"
      len-label
      ", %r8\n    sub $32, %rsp\n    call _write\n    add $32, %rsp\n    movq $"
      (int->string status)
      ", %rcx\n    sub $32, %rsp\n    call exit\n\n")))

(define (compiler-backend-runtime-windows-oob-functions) : String
  (compiler-backend-runtime-windows-fixed-abort-functions
    "tl_oob_abort"
    ".L_tl_oob_msg"
    ".L_tl_oob_msg_len"
    134))

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

(define (compiler-backend-runtime-windows-substring-functions) : String
  "    .globl tl_substring
tl_substring:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    addq %rdx, %rbx
    movq %r8, %r12
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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

(define (compiler-backend-runtime-windows-concat-functions) : String
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
    movq %rcx, %rbx
    movq %rdx, %r12
    movq %r8, %r13
    movq %r9, %r14
    movq %r12, %rcx
    addq %r14, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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

(define (compiler-backend-runtime-stdin-abort) : String
  "    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_stdin_error_msg(%rip), %rsi
    movq $.L_tl_stdin_error_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall
")

(define (compiler-backend-runtime-windows-stdin-abort) : String
  "    movq $2, %rcx
    leaq .L_tl_stdin_error_msg(%rip), %rdx
    movq $.L_tl_stdin_error_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit
")

(define (compiler-backend-runtime-read-stdin-line-functions) : String
  (string-append
    ".L_tl_read_stdin_line:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $16, %rsp
    movq $64, %r13
    movq %r13, %rdi
    call tl_alloc
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_read_stdin_line_loop:
    xorq %rax, %rax
    xorq %rdi, %rdi
    leaq -40(%rbp), %rsi
    movq $1, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_stdin_line_error
    jz .L_tl_read_stdin_line_eof
    cmpb $10, -40(%rbp)
    je .L_tl_read_stdin_line_done
    cmpq %r13, %r12
    jb .L_tl_read_stdin_line_store
    movq %r13, %rdi
    addq %r13, %rdi
    js .L_tl_read_stdin_line_error
    movq %rdi, %r14
    call tl_alloc
    xorq %rcx, %rcx
.L_tl_read_stdin_line_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_read_stdin_line_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%rax,%rcx)
    incq %rcx
    jmp .L_tl_read_stdin_line_copy_loop
.L_tl_read_stdin_line_copy_done:
    movq %rax, %rbx
    movq %r14, %r13
.L_tl_read_stdin_line_store:
    movzbl -40(%rbp), %eax
    movb %al, (%rbx,%r12)
    incq %r12
    jmp .L_tl_read_stdin_line_loop
.L_tl_read_stdin_line_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_line_return
.L_tl_read_stdin_line_done:
    movq $0, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_line_return:
    movq $16, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_line_error:
"
    (string-append (compiler-backend-runtime-stdin-abort) "\n")))

(define (compiler-backend-runtime-windows-read-stdin-line-functions) : String
  (string-append
    ".L_tl_read_stdin_line:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $16, %rsp
    movq $64, %r13
    movq %r13, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_read_stdin_line_loop:
    xorq %rcx, %rcx
    leaq -40(%rbp), %rdx
    movq $1, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    testq %rax, %rax
    js .L_tl_read_stdin_line_error
    jz .L_tl_read_stdin_line_eof
    cmpb $10, -40(%rbp)
    je .L_tl_read_stdin_line_done
    cmpq %r13, %r12
    jb .L_tl_read_stdin_line_store
    movq %r13, %rcx
    addq %r13, %rcx
    js .L_tl_read_stdin_line_error
    movq %rcx, %r14
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    xorq %r10, %r10
.L_tl_read_stdin_line_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_read_stdin_line_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%rax,%r10)
    incq %r10
    jmp .L_tl_read_stdin_line_copy_loop
.L_tl_read_stdin_line_copy_done:
    movq %rax, %rbx
    movq %r14, %r13
.L_tl_read_stdin_line_store:
    movzbl -40(%rbp), %eax
    movb %al, (%rbx,%r12)
    incq %r12
    jmp .L_tl_read_stdin_line_loop
.L_tl_read_stdin_line_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_line_return
.L_tl_read_stdin_line_done:
    movq $0, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_line_return:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_line_error:
"
    (string-append (compiler-backend-runtime-windows-stdin-abort) "\n")))

(define (compiler-backend-runtime-read-stdin-bytes-functions) : String
  (string-append
    ".L_tl_read_stdin_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %r12
    cmpq $0, %r12
    jl .L_tl_read_stdin_bytes_error
    movq %r12, %rdi
    cmpq $0, %rdi
    jg .L_tl_read_stdin_bytes_alloc_ready
    movq $1, %rdi
.L_tl_read_stdin_bytes_alloc_ready:
    call tl_alloc
    movq %rax, %rbx
    xorq %r13, %r13
    testq %r12, %r12
    jz .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_loop:
    cmpq %r12, %r13
    jge .L_tl_read_stdin_bytes_full
    movq %r12, %rdx
    subq %r13, %rdx
    xorq %rax, %rax
    xorq %rdi, %rdi
    leaq (%rbx,%r13), %rsi
    syscall
    testq %rax, %rax
    js .L_tl_read_stdin_bytes_error
    jz .L_tl_read_stdin_bytes_eof
    addq %rax, %r13
    jmp .L_tl_read_stdin_bytes_loop
.L_tl_read_stdin_bytes_full:
    movq $0, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_bytes_return:
    movq $16, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_bytes_error:
"
    (string-append (compiler-backend-runtime-stdin-abort) "\n")))

(define (compiler-backend-runtime-windows-read-stdin-bytes-functions) : String
  (string-append
    ".L_tl_read_stdin_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %r12
    cmpq $0, %r12
    jl .L_tl_read_stdin_bytes_error
    movq %r12, %rcx
    cmpq $0, %rcx
    jg .L_tl_read_stdin_bytes_alloc_ready
    movq $1, %rcx
.L_tl_read_stdin_bytes_alloc_ready:
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %rbx
    xorq %r13, %r13
    testq %r12, %r12
    jz .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_loop:
    cmpq %r12, %r13
    jge .L_tl_read_stdin_bytes_full
    xorq %rcx, %rcx
    leaq (%rbx,%r13), %rdx
    movq %r12, %r8
    subq %r13, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    testq %rax, %rax
    js .L_tl_read_stdin_bytes_error
    jz .L_tl_read_stdin_bytes_eof
    addq %rax, %r13
    jmp .L_tl_read_stdin_bytes_loop
.L_tl_read_stdin_bytes_full:
    movq $0, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_bytes_return:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rbx, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_bytes_error:
"
    (string-append (compiler-backend-runtime-windows-stdin-abort) "\n")))

(define (compiler-backend-runtime-stdin-eof-functions) : String
  ".L_tl_stdin_eof:
    movq .L_tl_stdin_eof_flag(%rip), %rax
    ret

")

(define (compiler-backend-runtime-flush-stdout-functions) : String
  ".L_tl_flush_stdout:
    ret

")

(define (compiler-backend-runtime-windows-flush-stdout-functions) : String
  ".L_tl_flush_stdout:
    push %rbp
    mov %rsp, %rbp
    xorq %rcx, %rcx
    sub $32, %rsp
    call fflush
    add $32, %rsp
    testl %eax, %eax
    jne .L_tl_flush_stdout_error
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_flush_stdout_error:
    movq $2, %rcx
    leaq .L_tl_flush_stdout_error_msg(%rip), %rdx
    movq $.L_tl_flush_stdout_error_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit

")

(define (compiler-backend-runtime-functions [plan : CompilerBackendRuntimePlan]) : String
  (compiler-backend-runtime-functions-for-target (BackendTargetLinux) plan))

(define (compiler-backend-runtime-functions-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        read-line
        read-bytes
        stdin-eof
        flush-stdout)
      (string-append
        (if alloc
          (if (compiler-backend-target-windows? target)
            (compiler-backend-runtime-windows-alloc-functions)
            (compiler-backend-runtime-alloc-functions))
          "")
        (string-append
          (if oob
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-oob-functions)
              (compiler-backend-runtime-oob-functions))
            "")
          (string-append
            (if substring
              (if (compiler-backend-target-windows? target)
                (compiler-backend-runtime-windows-substring-functions)
                (compiler-backend-runtime-substring-functions))
              "")
            (string-append
              (if concat
                (if (compiler-backend-target-windows? target)
                  (compiler-backend-runtime-windows-concat-functions)
                  (compiler-backend-runtime-concat-functions))
                "")
              (string-append
                (if read-line
                  (if (compiler-backend-target-windows? target)
                    (compiler-backend-runtime-windows-read-stdin-line-functions)
                    (compiler-backend-runtime-read-stdin-line-functions))
                  "")
                (string-append
                  (if read-bytes
                    (if (compiler-backend-target-windows? target)
                      (compiler-backend-runtime-windows-read-stdin-bytes-functions)
                      (compiler-backend-runtime-read-stdin-bytes-functions))
                    "")
                  (string-append
                    (if stdin-eof
                      (compiler-backend-runtime-stdin-eof-functions)
                      "")
                    (if flush-stdout
                      (if (compiler-backend-target-windows? target)
                        (compiler-backend-runtime-windows-flush-stdout-functions)
                        (compiler-backend-runtime-flush-stdout-functions))
                      ""))))))))]))

;; Argument register for call arg `idx` under the target's calling convention.

;; System V (Linux) uses rdi/rsi/rdx/rcx/r8/r9 via `compiler-backend-arg-reg`;

;; Windows x64 passes the first four integer/pointer args in rcx/rdx/r8/r9.

(define (compiler-backend-target-arg-reg
  [target : CompilerBackendTarget]
  [idx : i64]) : ResultBackendReg
  (match target
    [(BackendTargetLinux) (compiler-backend-arg-reg idx)]
    [(BackendTargetWindows)
      (if (= idx 0)
        (OkBackendReg "%rcx")
        (if (= idx 1)
          (OkBackendReg "%rdx")
          (if (= idx 2)
            (OkBackendReg "%r8")
            (if (= idx 3)
              (OkBackendReg "%r9")
              (ErrBackendReg "backend: too many call args")))))]))

;; Caller-reserved outgoing shadow space in bytes: none on System V, 32 on

;; Windows x64.

(define (compiler-backend-outgoing-shadow-space
  [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows) 32]))

;; Program entry section and global symbol. Linux links the bare `_start`;

;; Windows links `main` through the CRT. (The Windows entry body is #647.)

(define (compiler-backend-target-entry-text [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) ".text\n.globl _start\n"]
    [(BackendTargetWindows) ".text\n.globl main\n"]))

(define (compiler-backend-entry) : String
  "_start:\n    call main\n    movq %rax, %rdi\n    movq $60, %rax\n    syscall\n")

(define (compiler-backend-entry-for-target [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) (compiler-backend-entry)]
    [(BackendTargetWindows) ""]))

(define (compiler-backend-target-windows? [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux) false]
    [(BackendTargetWindows) true]))

(define (compiler-backend-runtime-plan-empty?
  [plan : CompilerBackendRuntimePlan]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        read-line
        read-bytes
        stdin-eof
        flush-stdout)
      (not
        (or
          alloc
          (or
            oob
            (or
              substring
              (or
                concat
                (or read-line (or read-bytes (or stdin-eof flush-stdout))))))))]))

(define (compiler-backend-target-runtime-ok?
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : bool
  true)

(define (compiler-backend-runtime-externs-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and
    (compiler-backend-target-windows? target)
    (not (compiler-backend-runtime-plan-empty? plan)))
    "    .extern malloc
    .extern _write
    .extern exit
    .extern _read
    .extern fflush
"
    ""))

;; Emit a full program for `target`. Windows x64 has ABI-correct user function

;; entry/calls and target-specific runtime helpers.

(define (compiler-backend-emit-program-for-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program target))

(define (compiler-backend-emit-program [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-linux [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (match (compiler-backend-runtime-plan program)
    [(OkBackendRuntimePlan plan)
      (if (compiler-backend-target-runtime-ok? target plan)
        (match program
          [(IrProgram globals functions externs)
            (match (compiler-backend-emit-globals globals)
              [(OkCompilerBackend globals-asm)
                (match (compiler-backend-emit-functions
                  target
                  functions
                  functions
                  externs
                  plan)
                  [(OkCompilerBackend functions-asm)
                    (let ([strings
                        :
                        BackendStringList
                        (compiler-backend-collect-program-strings program)]
                      [buf
                        :
                        TextBuf
                        (text-buf-append
                          (text-buf-append
                            (text-buf-append
                              (text-buf-append
                                (text-buf-append
                                  (text-buf-append
                                    (text-buf-append
                                      (text-buf-append
                                        (text-buf-append
                                          (text-buf-append
                                            (text-buf-empty)
                                            ".data\n")
                                          globals-asm)
                                        (compiler-backend-emit-string-rodata
                                          strings))
                                      (compiler-backend-runtime-data-for-target
                                        target
                                        plan))
                                    (compiler-backend-emit-externs externs plan))
                                  (compiler-backend-runtime-externs-for-target
                                    target
                                    plan))
                                (compiler-backend-target-entry-text target))
                              functions-asm)
                            (compiler-backend-runtime-functions-for-target
                              target
                              plan))
                          (compiler-backend-entry-for-target target))])
                      (OkCompilerBackend (text-buf-render buf)))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])])
        (ErrCompilerBackend
          (compiler-diagnostic-at-start
            ""
            "backend: internal target runtime rejection")))]
    [(ErrBackendRuntimePlan message)
      (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))

(define (compiler-backend-emit-source [src : String]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program) (compiler-backend-emit-program program)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-emit-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (compiler-backend-emit-program-for-target program target)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-char-code-at [text : String] [idx : i64]) : i64
  (compiler-backend-char-code (string-ref text idx)))

(define (compiler-backend-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let ([i : i64 0] [ok : bool true])
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (compiler-backend-char-code-at text (+ start i))
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
      (let ([i : i64 0] [found : bool false] [done : bool false])
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
        (IrExternCons (IrExtern "tl_string_concat" (AstTyI64)) IrExternNil)))))

(define (compiler-backend-runtime-helper-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        7
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
                    (IrInstrCall
                      3
                      ".L_tl_read_stdin_line"
                      IrValueNil
                      (AstTyString))
                    (IrInstrCons
                      (IrInstrCall
                        4
                        ".L_tl_read_stdin_bytes"
                        (IrValueCons (IrValueI64 0) IrValueNil)
                        (AstTyString))
                      (IrInstrCons
                        (IrInstrCall 5 ".L_tl_stdin_eof" IrValueNil (AstTyBool))
                        (IrInstrCons
                          (IrInstrCall
                            6
                            ".L_tl_flush_stdout"
                            IrValueNil
                            (AstTyUnit))
                          (IrInstrCons
                            (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                            IrInstrNil)))))))))
          IrBlockNil))
      IrFunctionNil)
    (compiler-backend-runtime-helper-externs)))

(define (compiler-backend-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-program
    (compiler-backend-runtime-helper-program))
    [(OkCompilerBackend asm)
      (let ([base-labels
          :
          bool
          (backend-and4
            (compiler-backend-string-contains? asm ".globl tl_alloc\n")
            (compiler-backend-string-contains? asm "tl_alloc:\n")
            (compiler-backend-string-contains? asm ".globl tl_oob_abort\n")
            (compiler-backend-string-contains? asm "tl_oob_abort:\n"))]
        [string-labels
          :
          bool
          (backend-and4
            (compiler-backend-string-contains? asm ".globl tl_substring\n")
            (compiler-backend-string-contains? asm "tl_substring:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
            (compiler-backend-string-contains? asm "tl_string_concat:\n"))]
        [stdio-labels
          :
          bool
          (backend-and4
            (compiler-backend-string-contains? asm ".L_tl_read_stdin_line:\n")
            (compiler-backend-string-contains? asm ".L_tl_read_stdin_bytes:\n")
            (compiler-backend-string-contains? asm ".L_tl_stdin_eof:\n")
            (compiler-backend-string-contains? asm ".L_tl_flush_stdout:\n"))]
        [no-externs
          :
          bool
          (backend-and8
            (not (compiler-backend-string-contains? asm ".extern tl_alloc\n"))
            (not
              (compiler-backend-string-contains? asm ".extern tl_oob_abort\n"))
            (not
              (compiler-backend-string-contains? asm ".extern tl_substring\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_string_concat\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_read_stdin_line\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_read_stdin_bytes\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_stdin_eof\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_flush_stdout\n")))])
        (and
          base-labels
          (and
            string-labels
            (and
              stdio-labels
              (and
                no-externs
                (and
                  (compiler-backend-string-contains? asm "    call tl_alloc\n")
                  (compiler-backend-string-contains?
                    asm
                    ".L_tl_stdin_eof_flag:\n")))))))]
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
  (match (compiler-backend-emit-program
    (compiler-backend-user-helper-name-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
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
  (match (compiler-backend-emit-program
    (compiler-backend-runtime-coexist-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm ".globl tl_alloc\n")
          (and
            (compiler-backend-string-contains? asm ".globl tl_substring\n")
            (and
              (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    call tl_substring\n")
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_substring\n")))))))]
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

(define (compiler-backend-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Nothing) (Circle i64) (Pair Point))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-none) : Shape
  Nothing)
(define (make-none-call) : Shape
  (Nothing))
(define (make-circle [r : i64]) : Shape
  (Circle r))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-backend-enum-match-source) : String
  "(defenum Maybe (None) (Some i64))
(define (score [m : Maybe]) : i64
  (match m
    [None 0]
    [(Some v) v]))
(define (main) : i64
  (score (Some 42)))")

(define (compiler-backend-regalloc-source) : String
  "(define (calc [a : i64] [b : i64]) : i64
  (let ([x : i64 (+ a b)]
        [y : i64 (* x 2)])
    (+ y x)))
(define (main) : i64
  (calc 10 5))")

(define (compiler-backend-asm-ok? [asm : String]) : bool
  (and
    (compiler-backend-string-contains? asm ".data\n")
    (and
      (compiler-backend-string-contains? asm ".text\n")
      (and
        (compiler-backend-string-contains? asm ".globl _start\n")
        (and
          (compiler-backend-string-contains? asm "_start:\n")
          (and
            (compiler-backend-string-contains? asm "main:\n")
            (and
              (compiler-backend-string-contains? asm "_tl_inc:\n")
              (and
                (compiler-backend-string-contains? asm "_tl_answer:\n")
                (and
                  (compiler-backend-string-contains? asm "    call _tl_inc\n")
                  (and
                    (compiler-backend-string-contains? asm "    setl %al\n")
                    (and
                      (compiler-backend-string-contains? asm "    setg %al\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "    cmpq $0, %rax\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "    jne .Lmain_while_body.1\n")
                          (compiler-backend-string-contains?
                            asm
                            "    jmp .Lmain_while_header.0\n"))))))))))))))

(define (compiler-backend-source-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-asm-ok? asm)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-string-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".L_tl_str_data_6869:")
        (and
          (compiler-backend-string-contains? asm ".L_tl_str_6869:")
          (and
            (compiler-backend-string-contains? asm "    .string \"hi\"\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    .quad .L_tl_str_data_6869\n")
              (and
                (compiler-backend-string-contains? asm "    .quad 2\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "_tl_greeting:\n    .quad .L_tl_str_6869\n")
                  (compiler-backend-string-contains?
                    asm
                    "    leaq .L_tl_str_6869(%rip), %rax\n")))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-aggregate-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-aggregate-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          "    movq $16, %rdi\n    call tl_alloc\n")
        (and
          (compiler-backend-string-contains?
            asm
            "    movq $0, %rax\n    movq %rax, (%r10)\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movq $1, %rax\n    movq %rax, (%r10)\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movq $8, %rbx\n    addq %rbx, %rax\n")
              (and
                (not
                  (compiler-backend-string-contains? asm "    call _tl_Point\n"))
                (and
                  (not
                    (compiler-backend-string-contains?
                      asm
                      "    call _tl_Nothing\n"))
                  (and
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    call _tl_Circle\n"))
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    call _tl_Pair\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-enum-match-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-enum-match-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_score:\n")
        (and
          (compiler-backend-string-contains? asm ".L_tl_score_match_arm.")
          (and
            (compiler-backend-string-contains? asm "    sete %al\n")
            (and
              (compiler-backend-string-contains? asm "    movq (%r10), %rax\n")
              (and
                (not
                  (compiler-backend-string-contains? asm "    call _tl_None\n"))
                (not
                  (compiler-backend-string-contains? asm "    call _tl_Some\n")))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-regalloc-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-regalloc-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_calc:\n")
        (and
          (compiler-backend-string-contains? asm "    movq %rdi, -8(%rbp)\n")
          (and
            (compiler-backend-string-contains? asm "    movq %rsi, -16(%rbp)\n")
            (and
              (compiler-backend-string-contains? asm "    movq %r12, -")
              (and
                (compiler-backend-string-contains? asm "    movq %rax, %r12\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    movq %r12, %rax\n")
                  (and
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    movq %rdi, %r12\n"))
                    (not
                      (compiler-backend-string-contains?
                        asm
                        "    movq %rsi, %r12\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-reg-is? [r : ResultBackendReg] [name : String]) : bool
  (match r
    [(OkBackendReg reg) (string-eq reg name)]
    [(ErrBackendReg _) false]))

(define (compiler-backend-reg-err? [r : ResultBackendReg]) : bool
  (match r
    [(OkBackendReg _) false]
    [(ErrBackendReg _) true]))

;; The target model (#646/#647): per-target arg registers / shadow space /

;; entry symbol; the Linux path is byte-identical to the default emitter and the

;; Windows path emits ABI-shaped user-function assembly and runtime helpers

;; without Linux syscalls.

(define (compiler-backend-target-model-ok? [src : String]) : bool
  (and
    (compiler-backend-reg-is?
      (compiler-backend-target-arg-reg (BackendTargetLinux) 0)
      "%rdi")
    (and
      (compiler-backend-reg-is?
        (compiler-backend-target-arg-reg (BackendTargetWindows) 0)
        "%rcx")
      (and
        (compiler-backend-reg-is?
          (compiler-backend-target-arg-reg (BackendTargetWindows) 3)
          "%r9")
        (and
          (compiler-backend-reg-err?
            (compiler-backend-target-arg-reg (BackendTargetWindows) 4))
          (and
            (= (compiler-backend-outgoing-shadow-space (BackendTargetLinux)) 0)
            (and
              (=
                (compiler-backend-outgoing-shadow-space (BackendTargetWindows))
                32)
              (and
                (compiler-backend-string-contains?
                  (compiler-backend-target-entry-text (BackendTargetLinux))
                  "_start")
                (and
                  (compiler-backend-string-contains?
                    (compiler-backend-target-entry-text (BackendTargetWindows))
                    ".globl main")
                  (and
                    (compiler-backend-target-linux-matches-default? src)
                    (and
                      (compiler-backend-target-windows-abi-ok?)
                      (and
                        (compiler-backend-target-windows-callee-save-ok?)
                        (compiler-backend-target-windows-runtime-ok?)))))))))))))

(define (compiler-backend-target-linux-matches-default? [src : String]) : bool
  (match (compiler-backend-emit-source-for-target src (BackendTargetLinux))
    [(OkCompilerBackend linux-asm)
      (match (compiler-backend-emit-source src)
        [(OkCompilerBackend default-asm) (string-eq linux-asm default-asm)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-abi-source) : String
  "(extern ext : (-> i64 i64 i64 i64 i64 i64))
(define (call5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
  (ext a b c d e))
(define (main) : i64
  (call5 1 2 3 4 5))")

(define (compiler-backend-target-windows-abi-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-target-windows-abi-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl main\n")
        (and
          (not (compiler-backend-string-contains? asm "_start:\n"))
          (and
            (not (compiler-backend-string-contains? asm "syscall\n"))
            (and
              (compiler-backend-string-contains?
                asm
                "    movq %rcx, -8(%rbp)\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movq %rdx, -16(%rbp)\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    movq %r8, -24(%rbp)\n")
                  (and
                    (compiler-backend-string-contains?
                      asm
                      "    movq %r9, -32(%rbp)\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    movq 48(%rbp), %rax\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "    subq $48, %rsp\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "    movq %rax, 32(%rsp)\n")
                          (and
                            (compiler-backend-string-contains?
                              asm
                              "    call ext\n")
                            (compiler-backend-string-contains?
                              asm
                              "    addq $48, %rsp\n"))))))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-callee-save-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-regalloc-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    movq %r12, -")
        (compiler-backend-string-contains? asm ", %r12\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-target-windows-runtime-ok?) : bool
  (match (compiler-backend-emit-program-for-target
    (compiler-backend-runtime-helper-program)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm "    call malloc\n")
          (and
            (compiler-backend-string-contains? asm "    call _write\n")
            (and
              (compiler-backend-string-contains? asm "    call _read\n")
              (and
                (compiler-backend-string-contains? asm "    call fflush\n")
                (and
                  (compiler-backend-string-contains? asm "tl_substring:\n")
                  (and
                    (compiler-backend-string-contains?
                      asm
                      "tl_string_concat:\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    .extern malloc\n")
                      (not (compiler-backend-string-contains? asm "syscall\n"))))))))))]
    [(ErrCompilerBackend message) false]))

(define (compiler-backend-deterministic-ok? [src : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend first)
      (match (compiler-backend-emit-source src)
        [(OkCompilerBackend second) (string-eq first second)]
        [(ErrCompilerBackend _) false])]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-error-ok? [src : String] [want : String]) : bool
  (match (compiler-backend-emit-source src)
    [(ErrCompilerBackend message)
      (string-eq (compiler-diagnostic-message message) want)]
    [(OkCompilerBackend _) false]))

(define (compiler-backend-instr-contains?
  [instr : CompilerIrInstr]
  [needle : String]) : bool
  (match (compiler-backend-emit-instr
    (BackendTargetLinux)
    "_tl_test"
    IrBlockNil
    "entry"
    instr
    CompilerRegAssignmentNil
    8
    (BackendRuntimePlan false false false false false false false false)
    IrFunctionNil
    IrExternNil)
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-memory-op-ok?) : bool
  (and
    (compiler-backend-instr-contains?
      (IrInstrAddrOf 2 1)
      "    leaq -16(%rbp), %rax\n")
    (and
      (compiler-backend-instr-contains?
        (IrInstrGep 3 (IrValueVar 1) (IrValueI64 2) (AstTyI32))
        "    imulq $4, %rbx\n")
      (and
        (compiler-backend-instr-contains?
          (IrInstrLoad 4 (IrValueVar 1) (AstTyU8))
          "    movzbq (%r10), %rax\n")
        (and
          (compiler-backend-instr-contains?
            (IrInstrStorePtr (IrValueVar 1) (IrValueI64 7) (AstTyI32))
            "    movl %eax, (%r10)\n")
          (compiler-backend-instr-contains?
            (IrInstrCast 6 (IrValueVar 5) (AstTyI8) (AstTyI64))
            "    movsbq -48(%rbp), %rax\n"))))))

;; A source exercising `array-ref`, used to confirm the lowerer's bounds-check

;; trap (#528) reaches the backend as a `call tl_oob_abort`.

(define (compiler-backend-array-access-source) : String
  "(define (get [a : (Array i64)] [i : i64]) : i64 (array-ref a i))
(define (main) : i64 0)")

(define (compiler-backend-array-access-asm-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-array-access-source))
    [(OkCompilerBackend asm)
      (compiler-backend-string-contains? asm "call tl_oob_abort")]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-make-array-source) : String
  "(define (main) : i64
  (let ([a : (Array i64) (make-array i64 2)])
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-ref a 0) (array-ref a 1)))))")

(define (compiler-backend-make-array-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-make-array-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "main:\n")
        (and
          (compiler-backend-string-contains? asm "    call tl_alloc\n")
          (and
            (compiler-backend-string-contains? asm "call tl_oob_abort")
            (compiler-backend-string-contains? asm "make_array_len_ok"))))]
    [(ErrCompilerBackend _) false]))

;; A refutable literal payload match (#651) lowers to a payload comparison that

;; branches to the next arm; confirm the resulting CFG reaches valid assembly.

(define (compiler-backend-literal-payload-source) : String
  "(defenum Maybe (None) (Some i64))
(define (classify [m : Maybe]) : i64
  (match m
    [(Some 0) 100]
    [(Some n) n]
    [None 5]))
(define (main) : i64 (classify (Some 0)))")

;; Confirm the refutable literal payload (#651) reaches valid assembly: the

;; function compiles and emits a `payload_ok` block (the in-bounds branch of the

;; payload comparison). `compiler-backend-asm-ok?` is smoke-source specific, so

;; check source-specific markers instead.

(define (compiler-backend-literal-payload-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-literal-payload-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "_tl_classify:\n")
        (compiler-backend-string-contains? asm "_payload_ok"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-self-test) : i64
  (if (and
    (compiler-backend-target-model-ok? (compiler-backend-smoke-source))
    (and
      (compiler-backend-array-access-asm-ok?)
      (and
        (compiler-backend-make-array-ok?)
        (and
          (compiler-backend-source-ok? (compiler-backend-smoke-source))
          (and
            (compiler-backend-deterministic-ok? (compiler-backend-smoke-source))
            (and
              (compiler-backend-string-ok?)
              (and
                (compiler-backend-memory-op-ok?)
                (and
                  (and
                    (compiler-backend-aggregate-ok?)
                    (compiler-backend-literal-payload-ok?))
                  (and
                    (compiler-backend-enum-match-ok?)
                    (and
                      (compiler-backend-regalloc-ok?)
                      (and
                        (compiler-backend-error-ok?
                          (compiler-backend-too-many-call-source)
                          "backend: too many call args")
                        (and
                          (compiler-backend-runtime-helper-asm-ok?)
                          (and
                            (compiler-backend-user-helper-name-ok?)
                            (compiler-backend-runtime-coexist-ok?))))))))))))))
    42
    (begin
      (panic "backend: smoke output mismatch")
      0)))