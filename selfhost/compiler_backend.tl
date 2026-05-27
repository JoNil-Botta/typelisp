;; compiler_backend.tl - First selfhost CompilerIrProgram -> x86_64 .s emitter (#447).
(import "compiler_lower.tl")

(import "compiler_diagnostic.tl")

(import "compiler_optimize.tl")

(import "compiler_regalloc.tl")

(import "text_buf.tl")

(defenum ResultBackendReg
  (OkBackendReg String)
  (ErrBackendReg String))

(defenum ResultBackendValue
  (OkBackendValue CompilerIrValue)
  (ErrBackendValue String))

(defenum CompilerBackendPhiSource
  (BackendPhiSourceValue CompilerIrValue)
  (BackendPhiSourceTemp))

(defenum CompilerBackendPhiCopy
  (BackendPhiCopy i64 CompilerBackendPhiSource AstType))

(defenum CompilerBackendPhiCopyList
  (BackendPhiCopyNil)
  (BackendPhiCopyCons CompilerBackendPhiCopy CompilerBackendPhiCopyList))

(defenum CompilerBackendMaybePhiCopy
  (BackendNoPhiCopy)
  (BackendSomePhiCopy CompilerBackendPhiCopy))

(defenum ResultBackendPhiCopies
  (OkBackendPhiCopies CompilerBackendPhiCopyList)
  (ErrBackendPhiCopies String))

(defenum CompilerBackendMaybeImmediate
  (CompilerBackendNoImmediate)
  (CompilerBackendSomeImmediate String))

(defenum CompilerBackendMaybeAsm
  (CompilerBackendNoAsm)
  (CompilerBackendSomeAsm String))

(defenum ResultCompilerBackend
  (OkCompilerBackend String)
  (ErrCompilerBackend CompilerDiagnostic))

(defenum CompilerBackendRuntimePlan
  (BackendRuntimePlan
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool))

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

(define (backend-or4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (or a (or b (or c d))))

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

(define (backend-or8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (or (backend-or4 a b c d) (backend-or4 e f g h)))

;; Best-available diagnostic for a backend error originating inside `function`
;;
;; (#605). When the lowering provenance side table has a source span for the
;;
;; function, the diagnostic is stamped with that real line/column via
;;
;; `compiler-diagnostic-from-ast-span`; otherwise it falls back to the previous
;;
;; `path:1:1` location. `function` is the raw IR function name (the key used by
;;
;; the spans table), not the mangled assembly symbol.
(define (compiler-backend-function-diagnostic
  [spans : CompilerSourceSpans]
  [function : String]
  [message : String]) : CompilerDiagnostic
  (match (compiler-source-spans-lookup spans function)
    [(CompilerSomeSourceSpan span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [(CompilerNoSourceSpan) (compiler-diagnostic-at-start "" message)]))

(define (compiler-backend-instr-diagnostic
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [fallback : CompilerDiagnostic]
  [message : String]) : CompilerDiagnostic
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerSomeSourceSpan span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [(CompilerNoSourceSpan) (compiler-diagnostic-with-message fallback message)]))

(define (compiler-backend-apply-instr-diagnostic
  [diag : CompilerDiagnostic]
  [instr-diag : CompilerDiagnostic]) : CompilerDiagnostic
  (compiler-diagnostic-with-message
    instr-diag
    (compiler-diagnostic-message diag)))

(define (compiler-backend-vector-mask-unimplemented
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      "backend: vector/mask IR emission is not implemented")))

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
          (let
            [tail : CompilerRegAssignmentList
              (compiler-backend-drop-param-assignments rest params)]
            (if (compiler-backend-param-var? params var)
              tail
              (CompilerRegAssignmentCons item tail)))])]))

(define (compiler-backend-callee-save-slot [vars : i64] [idx : i64]) : String
  (compiler-backend-frame-offset (- 0 (* 8 (+ vars (+ idx 1))))))

(define (compiler-backend-asm-label [function : String] [label : String]) : String
  (backend-cat4 ".L" (compiler-backend-asm-safe-symbol function) "_" label))

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

(define (compiler-backend-float-arg-reg [idx : i64]) : ResultBackendReg
  (if (= idx 0)
    (OkBackendReg "%xmm0")
    (if (= idx 1)
      (OkBackendReg "%xmm1")
      (if (= idx 2)
        (OkBackendReg "%xmm2")
        (if (= idx 3)
          (OkBackendReg "%xmm3")
          (if (= idx 4)
            (OkBackendReg "%xmm4")
            (if (= idx 5)
              (OkBackendReg "%xmm5")
              (if (= idx 6)
                (OkBackendReg "%xmm6")
                (if (= idx 7)
                  (OkBackendReg "%xmm7")
                  (ErrBackendReg "backend: too many call args"))))))))))

(define (compiler-backend-emit-stack-sub [frame : i64]) : String
  (if (= frame 0)
    ""
    (backend-cat4 "    subq $" (int->string frame) ", %rsp\n" "")))

(define (compiler-backend-emit-store-var [var-id : i64] [reg : String]) : String
  (backend-cat5 "    movq " reg ", " (compiler-backend-slot var-id) "\n"))

(define (compiler-backend-emit-store-xmm-var [var-id : i64] [reg : String]) : String
  (backend-cat5 "    movsd " reg ", " (compiler-backend-slot var-id) "\n"))

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

(define (compiler-backend-emit-load-f64-var-with-plan
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
            "    movsd "
            (compiler-backend-frame-offset offset)
            ", "
            reg
            "\n")])]
    [(CompilerRegNoLocation)
      (backend-cat5 "    movsd " (compiler-backend-slot var-id) ", " reg "\n")]))

(define (compiler-backend-emit-store-f64-var-with-plan
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
            "    movsd "
            reg
            ", "
            (compiler-backend-frame-offset offset)
            "\n")])]
    [(CompilerRegNoLocation) (compiler-backend-emit-store-xmm-var var-id reg)]))

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

(define (compiler-backend-imm32? [n : i64]) : bool
  (and (>= n (- 0 2147483648)) (<= n 2147483647)))

(define (compiler-backend-immediate-i64 [n : i64]) : CompilerBackendMaybeImmediate
  (if (compiler-backend-imm32? n)
    (CompilerBackendSomeImmediate (string-append "$" (int->string n)))
    (CompilerBackendNoImmediate)))

(define (compiler-backend-immediate-operand [value : CompilerIrValue]) : CompilerBackendMaybeImmediate
  (match value
    [(IrValueI64 n) (compiler-backend-immediate-i64 n)]
    [(IrValueBool b)
      (if b
        (CompilerBackendSomeImmediate "$1")
        (CompilerBackendSomeImmediate "$0"))]
    [(IrValueChar c)
      (CompilerBackendSomeImmediate
        (string-append "$" (int->string (compiler-backend-char-code c))))]
    [(IrValueUnit) (CompilerBackendSomeImmediate "$0")]
    [_ (CompilerBackendNoImmediate)]))

(define (compiler-backend-symbol-char [text : String] [idx : i64] [c : char]) : String
  (if (or
    (and (>= c #A') (<= c #Z'))
    (or (and (>= c #a') (<= c #z')) (or (and (>= c #0') (<= c #9')) (= c #_'))))
    (substring text idx 1)
    (if (= c #-')
      "_"
      (if (= c #?')
        "_question"
        (if (= c #!')
          "_bang"
          (if (= c #+')
            "_plus"
            (if (= c #*')
              "_star"
              (if (= c #/')
                "_slash"
                (if (= c #=')
                  "_eq"
                  (if (= c #<')
                    "_lt"
                    (if (= c #>')
                      "_gt"
                      (if (= c #:')
                        "_colon"
                        (string-append
                          "_u"
                          (compiler-backend-hex-byte
                            (compiler-backend-char-code c)))))))))))))))

(define (compiler-backend-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref name i)]
          (begin
            (set!
              out
              (string-append out (compiler-backend-symbol-char name i c)))
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
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (compiler-backend-type-size inner)]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyVar _) 8]))

(define (compiler-backend-f64-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [_ false]))

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
  [c : char]) : String
  (if (= c #"')
    "\\\""
    (if (= c #\\')
      "\\\\"
      (if (= c #\newline')
        "\\n"
        (if (= c #\tab')
          "\\t"
          (if (= c #\return')
            "\\r"
            (if (and (>= c #\space') (<= c #~'))
              (substring text idx 1)
              (compiler-backend-octal-escape (compiler-backend-char-code c)))))))))

(define (compiler-backend-escape-string [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (begin
            (set!
              out
              (string-append out (compiler-backend-escape-string-byte text i c)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-quoted-gas-string [text : String]) : String
  (string-append
    "\""
    (string-append (compiler-backend-escape-string text) "\"")))

(define (compiler-backend-string-label-suffix [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (string-append
              out
              (compiler-backend-hex-byte
                (compiler-backend-char-code (string-ref text i)))))
          (set! i (+ i 1))))
      (if (= n 0)
        "empty"
        out))))

(define (compiler-backend-string-data-label [text : String]) : String
  (string-append ".L_tl_str_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-string-fat-label [text : String]) : String
  (string-append ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-f64-label [text : String]) : String
  (string-append ".L_tl_f64_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-emit-load-f64-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (match value
    [(IrValueVar id)
      (OkCompilerBackend
        (compiler-backend-emit-load-f64-var-with-plan assignments id reg))]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (backend-cat5
          "    movsd "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueF64 text)
      (OkCompilerBackend
        (backend-cat5
          "    movsd "
          (compiler-backend-f64-label text)
          "(%rip), "
          reg
          "\n"))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: expected f64 value"))]))

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
  (let
    [size : i64 (compiler-backend-type-size ty)]
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

(define (compiler-backend-emit-load-f64-memory [addr : String] [reg : String]) : String
  (backend-cat5 "    movsd " addr ", " reg "\n"))

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
          (if (string-eq reg "%r15")
            (if (= size 4)
              "%r15d"
              (if (= size 2)
                "%r15w"
                "%r15b"))
            (if (string-eq reg "%r8")
              (if (= size 4)
                "%r8d"
                (if (= size 2)
                  "%r8w"
                  "%r8b"))
              (if (string-eq reg "%r9")
                (if (= size 4)
                  "%r9d"
                  (if (= size 2)
                    "%r9w"
                    "%r9b"))
                (if (= size 4)
                  "%r15d"
                  (if (= size 2)
                    "%r15w"
                    "%r15b"))))))))))

(define (compiler-backend-emit-load-register [reg : String] [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
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
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (if (= size 8)
      (backend-cat3 "    movq %rax, " addr "\n")
      (if (= size 4)
        (backend-cat3 "    movl %eax, " addr "\n")
        (if (= size 2)
          (backend-cat3 "    movw %ax, " addr "\n")
          (if (= size 1)
            (backend-cat3 "    movb %al, " addr "\n")
            ""))))))

(define (compiler-backend-emit-store-xmm-to-memory
  [addr : String]
  [reg : String]) : String
  (backend-cat5 "    movsd " reg ", " addr "\n"))

(define (compiler-backend-emit-store-typed-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]
  [ty : AstType]) : String
  (if (compiler-backend-f64-type? ty)
    (compiler-backend-emit-store-f64-var-with-plan assignments var-id reg)
    (compiler-backend-emit-store-var-with-plan assignments var-id reg)))

(define (compiler-backend-emit-load-typed-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-f64-type? ty)
    (compiler-backend-emit-load-f64-value-with-plan assignments value "%xmm0")
    (match value
      [(IrValueVar id)
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister home)
                (OkCompilerBackend
                  (compiler-backend-emit-load-register home ty))]
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
      [_ (compiler-backend-emit-load-value-with-plan assignments value "%rax")])))

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

(define (compiler-backend-value-f64?
  [types : CompilerRegVarTypeList]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueF64 _) true]
    [(IrValueVar id)
      (match (compiler-reg-var-type-lookup types id)
        [(CompilerRegSomeType ty) (compiler-backend-f64-type? ty)]
        [(CompilerRegNoType) false])]
    [_ false]))

(define (compiler-backend-binop-f64?
  [types : CompilerRegVarTypeList]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : bool
  (if (compiler-backend-f64-type? ty)
    true
    (if (compiler-backend-value-f64? types lhs)
      true
      (compiler-backend-value-f64? types rhs))))

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

(define (compiler-backend-binop-immediate-asm
  [op : CompilerIrBinOp]
  [imm : String]
  [ty : AstType]) : CompilerBackendMaybeAsm
  (match op
    [(IrBinAdd)
      (CompilerBackendSomeAsm (backend-cat3 "    addq " imm ", %rax\n"))]
    [(IrBinSub)
      (CompilerBackendSomeAsm (backend-cat3 "    subq " imm ", %rax\n"))]
    [(IrBinEq)
      (CompilerBackendSomeAsm
        (backend-cat3
          "    cmpq "
          imm
          ", %rax\n    sete %al\n    movzbq %al, %rax\n"))]
    [(IrBinNe)
      (CompilerBackendSomeAsm
        (backend-cat3
          "    cmpq "
          imm
          ", %rax\n    setne %al\n    movzbq %al, %rax\n"))]
    [(IrBinLt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setb %al\n    movzbq %al, %rax\n"))
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setl %al\n    movzbq %al, %rax\n")))]
    [(IrBinLe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setbe %al\n    movzbq %al, %rax\n"))
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setle %al\n    movzbq %al, %rax\n")))]
    [(IrBinGt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    seta %al\n    movzbq %al, %rax\n"))
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setg %al\n    movzbq %al, %rax\n")))]
    [(IrBinGe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setae %al\n    movzbq %al, %rax\n"))
        (CompilerBackendSomeAsm
          (backend-cat3
            "    cmpq "
            imm
            ", %rax\n    setge %al\n    movzbq %al, %rax\n")))]
    [(IrBinAnd)
      (CompilerBackendSomeAsm (backend-cat3 "    andq " imm ", %rax\n"))]
    [(IrBinOr)
      (CompilerBackendSomeAsm (backend-cat3 "    orq " imm ", %rax\n"))]
    [(IrBinBitAnd)
      (CompilerBackendSomeAsm (backend-cat3 "    andq " imm ", %rax\n"))]
    [(IrBinBitOr)
      (CompilerBackendSomeAsm (backend-cat3 "    orq " imm ", %rax\n"))]
    [(IrBinBitXor)
      (CompilerBackendSomeAsm (backend-cat3 "    xorq " imm ", %rax\n"))]
    [_ (CompilerBackendNoAsm)]))

(define (compiler-backend-unop-asm [op : CompilerIrUnOp]) : String
  (match op
    [(IrUnNeg) "    negq %rax\n"]
    [(IrUnNot) "    testq %rax, %rax\n    sete %al\n    movzbq %al, %rax\n"]
    [(IrUnBitNot) "    notq %rax\n"]))

(define (compiler-backend-f64-binop-asm [op : CompilerIrBinOp]) : ResultCompilerBackend
  (match op
    [(IrBinAdd) (OkCompilerBackend "    addsd %xmm1, %xmm0\n")]
    [(IrBinSub) (OkCompilerBackend "    subsd %xmm1, %xmm0\n")]
    [(IrBinMul) (OkCompilerBackend "    mulsd %xmm1, %xmm0\n")]
    [(IrBinDiv) (OkCompilerBackend "    divsd %xmm1, %xmm0\n")]
    [(IrBinEq)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    sete %al\n    movzbq %al, %rax\n")]
    [(IrBinNe)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    setne %al\n    movzbq %al, %rax\n")]
    [(IrBinLt)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    setb %al\n    movzbq %al, %rax\n")]
    [(IrBinLe)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    setbe %al\n    movzbq %al, %rax\n")]
    [(IrBinGt)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    seta %al\n    movzbq %al, %rax\n")]
    [(IrBinGe)
      (OkCompilerBackend
        "    ucomisd %xmm1, %xmm0\n    setae %al\n    movzbq %al, %rax\n")]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: unsupported f64 binary op"))]))

(define (compiler-backend-f64-unop-asm [op : CompilerIrUnOp]) : ResultCompilerBackend
  (match op
    [(IrUnNeg)
      (OkCompilerBackend
        "    movabsq $0x8000000000000000, %rax\n    movq %rax, %xmm1\n    xorpd %xmm1, %xmm0\n")]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: unsupported f64 unary op"))]))

(define (compiler-backend-emit-binop
  [types : CompilerRegVarTypeList]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-binop-f64? types lhs rhs ty)
    (match (compiler-backend-emit-load-f64-value-with-plan
      assignments
      lhs
      "%xmm0")
      [(OkCompilerBackend lhs-asm)
        (match (compiler-backend-emit-load-f64-value-with-plan
          assignments
          rhs
          "%xmm1")
          [(OkCompilerBackend rhs-asm)
            (match (compiler-backend-f64-binop-asm op)
              [(OkCompilerBackend op-asm)
                (OkCompilerBackend
                  (string-append
                    lhs-asm
                    (string-append
                      rhs-asm
                      (string-append
                        op-asm
                        (if (compiler-backend-f64-type? ty)
                          (compiler-backend-emit-store-f64-var-with-plan
                            assignments
                            dst
                            "%xmm0")
                          (compiler-backend-emit-store-var-with-plan
                            assignments
                            dst
                            "%rax"))))))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])
    (match (compiler-backend-emit-load-value-with-plan assignments lhs "%rax")
      [(OkCompilerBackend lhs-asm)
        (match (compiler-backend-immediate-operand rhs)
          [(CompilerBackendSomeImmediate imm)
            (match (compiler-backend-binop-immediate-asm op imm ty)
              [(CompilerBackendSomeAsm op-asm)
                (OkCompilerBackend
                  (string-append
                    lhs-asm
                    (string-append
                      op-asm
                      (compiler-backend-emit-store-var-with-plan
                        assignments
                        dst
                        "%rax"))))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-emit-load-value-with-plan
                  assignments
                  rhs
                  "%rbx")
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
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
          [(CompilerBackendNoImmediate)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              rhs
              "%rbx")
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
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-jump-label [function : String] [label : String]) : String
  (backend-cat4 "    jmp " (compiler-backend-asm-label function label) "\n" ""))

(define (compiler-backend-emit-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [cond : CompilerIrValue]
  [true-label : String]
  [false-label : String]) : ResultCompilerBackend
  (match cond
    [(IrValueBool b)
      (if b
        (OkCompilerBackend (compiler-backend-jump-label function true-label))
        (OkCompilerBackend (compiler-backend-jump-label function false-label)))]
    [_
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        cond
        "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (string-append
                "    testq %rax, %rax\n"
                (backend-cat5
                  "    jne "
                  (compiler-backend-asm-label function true-label)
                  "\n    jmp "
                  (compiler-backend-asm-label function false-label)
                  "\n"))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-bounds-check
  [target : CompilerBackendTarget]
  [function : String]
  [assignments : CompilerRegAssignmentList]
  [index : CompilerIrValue]
  [length : CompilerIrValue]
  [ok-label : String]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments index "%rax")
    [(OkCompilerBackend index-asm)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        length
        "%r11")
        [(OkCompilerBackend length-asm)
          (let
            [call-space : i64
              (compiler-backend-call-arg-space target IrValueNil AstTypeNil)]
            [ok-symbol : String (compiler-backend-asm-label function ok-label)]
            (OkCompilerBackend
              (string-append
                index-asm
                (string-append
                  length-asm
                  (string-append
                    (backend-cat4
                      "    cmpq %r11, %rax\n    jb "
                      ok-symbol
                      "\n"
                      "")
                    (string-append
                      (compiler-backend-emit-call-space-sub call-space)
                      (backend-cat5
                        "    call "
                        (compiler-backend-call-symbol
                          "tl_oob_abort"
                          plan
                          functions
                          externs)
                        "\n"
                        (string-append
                          (compiler-backend-emit-call-space-add call-space)
                          (backend-cat4 ok-symbol ":\n" "" ""))
                        "")))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-unop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrUnOp]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-f64-type? ty)
    (match (compiler-backend-emit-load-f64-value-with-plan
      assignments
      src
      "%xmm0")
      [(OkCompilerBackend src-asm)
        (match (compiler-backend-f64-unop-asm op)
          [(OkCompilerBackend op-asm)
            (OkCompilerBackend
              (string-append
                src-asm
                (string-append
                  op-asm
                  (compiler-backend-emit-store-f64-var-with-plan
                    assignments
                    dst
                    "%xmm0"))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])
    (match (compiler-backend-emit-load-value-with-plan assignments src "%rax")
      [(OkCompilerBackend src-asm)
        (OkCompilerBackend
          (string-append
            src-asm
            (string-append
              (compiler-backend-unop-asm op)
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

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
          (let
            [scale : i64 (compiler-backend-type-size elem-ty)]
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
        (if (compiler-backend-f64-type? ty)
          (string-append
            ptr-asm
            (string-append
              (compiler-backend-emit-load-f64-memory "(%r10)" "%xmm0")
              (compiler-backend-emit-store-f64-var-with-plan
                assignments
                dst
                "%xmm0")))
          (string-append
            ptr-asm
            (string-append
              (compiler-backend-emit-load-memory "(%r10)" ty)
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))))]
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
                (if (compiler-backend-f64-type? ty)
                  (compiler-backend-emit-store-xmm-to-memory "(%r10)" "%xmm0")
                  (compiler-backend-emit-store-rax-to-memory "(%r10)" ty)))))]
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
          (compiler-backend-emit-store-typed-var-with-plan
            assignments
            dst
            (if (compiler-backend-f64-type? to-ty)
              "%xmm0"
              "%rax")
            to-ty)))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-ir-value-list-count [args : CompilerIrValueList]) : i64
  (match args
    [(IrValueNil) 0]
    [(IrValueCons _ rest) (+ 1 (compiler-backend-ir-value-list-count rest))]))

(define (compiler-backend-call-register-count [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 6]
    [(BackendTargetWindows) 4]))

;; Number of f64 argument registers (#750). System V uses xmm0..xmm7 (8) and
;; Windows shares its 4 positional slots, so the float bank also tops out at 4.
(define (compiler-backend-call-float-register-count
  [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 8]
    [(BackendTargetWindows) 4]))

(define (compiler-backend-emit-call-space-sub [space : i64]) : String
  (if (= space 0)
    ""
    (backend-cat4 "    subq $" (int->string space) ", %rsp\n" "")))

(define (compiler-backend-emit-call-space-add [space : i64]) : String
  (if (= space 0)
    ""
    (backend-cat4 "    addq $" (int->string space) ", %rsp\n" "")))

;; Whether the argument at the given bank indexes is passed on the stack
;; (#750). Windows shares one positional slot bank (`position`); System V keeps
;; the integer and float banks independent, so an arg spills only once its own
;; bank is exhausted (rdi..r9 / xmm0..xmm7).
(define (compiler-backend-stack-call-arg-for-banks?
  [target : CompilerBackendTarget]
  [is-f64 : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : bool
  (match target
    [(BackendTargetWindows)
      (>= position (compiler-backend-call-register-count target))]
    [(BackendTargetLinux)
      (if is-f64
        (>= float-idx (compiler-backend-call-float-register-count target))
        (>= int-idx (compiler-backend-call-register-count target)))]))

(define (compiler-backend-param-type-list [params : CompilerIrParamList]) : AstTypeList
  (match params
    [(IrParamNil) AstTypeNil]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty _)
          (AstTypeCons ty (compiler-backend-param-type-list rest))])]))

(define (compiler-backend-function-param-types
  [functions : CompilerIrFunctionList]
  [name : String]) : AstTypeList
  (match functions
    [(IrFunctionNil) AstTypeNil]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname params _ _ _)
          (if (string-eq fname name)
            (compiler-backend-param-type-list params)
            (compiler-backend-function-param-types rest name))])]))

(define (compiler-backend-extern-param-types
  [externs : CompilerIrExternList]
  [name : String]) : AstTypeList
  (match externs
    [(IrExternNil) AstTypeNil]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty)
          (if (string-eq extern-name name)
            (match ty
              [(AstTyFunc args _) args]
              [_ AstTypeNil])
            (compiler-backend-extern-param-types rest name))])]))

(define (compiler-backend-call-param-types
  [name : String]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : AstTypeList
  (let
    [local-types : AstTypeList
      (compiler-backend-function-param-types functions name)]
    (match local-types
      [(AstTypeNil) (compiler-backend-extern-param-types externs name)]
      [_ local-types])))

;; Byte offset from %rsp where the `stack-idx`-th stack-passed OUTGOING argument
;; is stored (#750). Stack args are numbered sequentially in argument order (0,
;; 1, ...) independent of which register bank overflowed. System V packs them at
;; 0,8,16,...; Windows packs them after the 32-byte shadow space.
(define (compiler-backend-outgoing-stack-arg-offset
  [target : CompilerBackendTarget]
  [stack-idx : i64]) : i64
  (+ (compiler-backend-outgoing-shadow-space target) (* stack-idx 8)))

;; Byte offset from %rbp where the `stack-idx`-th INCOMING stack argument lives
;; (#750). System V's first stack arg sits at 16(%rbp) (saved %rbp + return
;; address); Windows adds its 32-byte shadow space (48(%rbp)).
(define (compiler-backend-incoming-stack-arg-offset
  [target : CompilerBackendTarget]
  [stack-idx : i64]) : i64
  (+ (+ 16 (compiler-backend-outgoing-shadow-space target)) (* stack-idx 8)))

;; Count the OUTGOING arguments that must be passed on the stack (#750). Walks
;; the args in order, tracking the integer/float/position banks exactly as
;; `compiler-backend-emit-call-args` does, and counts every arg whose bank is
;; already full.
(define (compiler-backend-call-stack-arg-count
  [target : CompilerBackendTarget]
  [args : CompilerIrValueList]
  [types : AstTypeList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]) : i64
  (match args
    [(IrValueNil) stack-count]
    [(IrValueCons value rest)
      (let
        [arg-ty : AstType
          (match types
            [(AstTypeCons ty _) ty]
            [(AstTypeNil) (AstTyI64)])]
        [rest-types : AstTypeList
          (match types
            [(AstTypeCons _ tail) tail]
            [(AstTypeNil) AstTypeNil])]
        (let
          [is-f64 : bool (compiler-backend-f64-type? arg-ty)]
          (compiler-backend-call-stack-arg-count
            target
            rest
            rest-types
            (if is-f64
              int-idx
              (+ int-idx 1))
            (if is-f64
              (+ float-idx 1)
              float-idx)
            (+ position 1)
            (if (compiler-backend-stack-call-arg-for-banks?
              target
              is-f64
              int-idx
              float-idx
              position)
              (+ stack-count 1)
              stack-count))))]))

;; Total %rsp adjustment reserved for a call's stack-passed args (#750):
;; `roundup16(shadow + stack-arg-count * 8)`. System V has no shadow space, so
;; this is 0 whenever every arg fits in registers.
(define (compiler-backend-call-arg-space
  [target : CompilerBackendTarget]
  [args : CompilerIrValueList]
  [types : AstTypeList]) : i64
  (let
    [stack-count : i64
      (compiler-backend-call-stack-arg-count target args types 0 0 0 0)]
    (if (and (= stack-count 0) (not (compiler-backend-target-windows? target)))
      0
      (compiler-backend-round-up-16
        (+ (compiler-backend-outgoing-shadow-space target) (* stack-count 8))))))

(define (compiler-backend-emit-call-args
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrValueList]
  [types : AstTypeList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match args
    [(IrValueNil) (OkCompilerBackend "")]
    [(IrValueCons value rest)
      (let
        [arg-ty : AstType
          (match types
            [(AstTypeCons ty _) ty]
            [(AstTypeNil) (AstTyI64)])]
        [rest-types : AstTypeList
          (match types
            [(AstTypeCons _ tail) tail]
            [(AstTypeNil) AstTypeNil])]
        (let
          [is-f64 : bool (compiler-backend-f64-type? arg-ty)]
          (let
            [next-int : i64
              (if is-f64
                int-idx
                (+ int-idx 1))]
            [next-float : i64
              (if is-f64
                (+ float-idx 1)
                float-idx)]
            (if (compiler-backend-stack-call-arg-for-banks?
              target
              is-f64
              int-idx
              float-idx
              position)
              ;; Stack-passed arg: load into a scratch register that no other
              ;; call arg uses (%xmm15 / %r11, matching the Rust backend) so an
              ;; earlier register arg in xmm0/%rax is never clobbered, then
              ;; store it at its %rsp offset.
              (match (if is-f64
                (compiler-backend-emit-load-f64-value-with-plan
                  assignments
                  value
                  "%xmm15")
                (compiler-backend-emit-load-value-with-plan
                  assignments
                  value
                  "%r11"))
                [(OkCompilerBackend head)
                  (match (compiler-backend-emit-call-args
                    target
                    assignments
                    rest
                    rest-types
                    next-int
                    next-float
                    (+ position 1)
                    (+ stack-idx 1)
                    func-diag)
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend
                        (backend-cat5
                          head
                          (if is-f64
                            "    movsd %xmm15, "
                            "    movq %r11, ")
                          (int->string
                            (compiler-backend-outgoing-stack-arg-offset
                              target
                              stack-idx))
                          "(%rsp)\n"
                          tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])
              (match (if is-f64
                (compiler-backend-target-float-arg-reg
                  target
                  (if (compiler-backend-target-windows? target)
                    position
                    float-idx))
                (compiler-backend-target-arg-reg
                  target
                  (if (compiler-backend-target-windows? target)
                    position
                    int-idx)))
                [(OkBackendReg reg)
                  (match (if is-f64
                    (compiler-backend-emit-load-f64-value-with-plan
                      assignments
                      value
                      reg)
                    (compiler-backend-emit-load-value-with-plan
                      assignments
                      value
                      reg))
                    [(OkCompilerBackend head)
                      (match (compiler-backend-emit-call-args
                        target
                        assignments
                        rest
                        rest-types
                        next-int
                        next-float
                        (+ position 1)
                        stack-idx
                        func-diag)
                        [(OkCompilerBackend tail)
                          (OkCompilerBackend (string-append head tail))]
                        [(ErrCompilerBackend message)
                          (ErrCompilerBackend message)])]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrBackendReg message)
                  (ErrCompilerBackend
                    (compiler-diagnostic-with-message func-diag message))])))))]))

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

(define (compiler-backend-vars-same-home?
  [assignments : CompilerRegAssignmentList]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (match (compiler-reg-assignment-lookup assignments left)
      [(CompilerRegSomeLocation left-location)
        (match (compiler-reg-assignment-lookup assignments right)
          [(CompilerRegSomeLocation right-location)
            (compiler-reg-location-eq? left-location right-location)]
          [(CompilerRegNoLocation) false])]
      [(CompilerRegNoLocation) false])))

(define (compiler-backend-phi-same-home?
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar src) (compiler-backend-vars-same-home? assignments src dst)]
    [_ false]))

(define (compiler-backend-phi-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [source : CompilerBackendPhiSource]
  [dst : i64]) : bool
  (match source
    [(BackendPhiSourceValue value)
      (match value
        [(IrValueVar found)
          (compiler-backend-vars-same-home? assignments found dst)]
        [_ false])]
    [(BackendPhiSourceTemp) false]))

(define (compiler-backend-phi-copy-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [copy : CompilerBackendPhiCopy]
  [dst : i64]) : bool
  (match copy
    [(BackendPhiCopy _ source _)
      (compiler-backend-phi-source-uses-home? assignments source dst)]))

(define (compiler-backend-phi-copy-list-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]
  [dst : i64]) : bool
  (match copies
    [(BackendPhiCopyNil) false]
    [(BackendPhiCopyCons copy rest)
      (if (compiler-backend-phi-copy-source-uses-home? assignments copy dst)
        true
        (compiler-backend-phi-copy-list-source-uses-home? assignments rest dst))]))

(define (compiler-backend-phi-copy-list-find-unblocked
  [assignments : CompilerRegAssignmentList]
  [remaining : CompilerBackendPhiCopyList]
  [all : CompilerBackendPhiCopyList]) : CompilerBackendMaybePhiCopy
  (match remaining
    [(BackendPhiCopyNil) BackendNoPhiCopy]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy dst _ _)
          (if (compiler-backend-phi-copy-list-source-uses-home?
            assignments
            all
            dst)
            (compiler-backend-phi-copy-list-find-unblocked assignments rest all)
            (BackendSomePhiCopy copy))])]))

(define (compiler-backend-phi-copy-list-remove-dst
  [copies : CompilerBackendPhiCopyList]
  [dst : i64]) : CompilerBackendPhiCopyList
  (match copies
    [(BackendPhiCopyNil) BackendPhiCopyNil]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy found-dst _ _)
          (if (= found-dst dst)
            (compiler-backend-phi-copy-list-remove-dst rest dst)
            (BackendPhiCopyCons
              copy
              (compiler-backend-phi-copy-list-remove-dst rest dst)))])]))

(define (compiler-backend-phi-source-replace-home
  [assignments : CompilerRegAssignmentList]
  [source : CompilerBackendPhiSource]
  [dst : i64]) : CompilerBackendPhiSource
  (match source
    [(BackendPhiSourceValue value)
      (match value
        [(IrValueVar found)
          (if (compiler-backend-vars-same-home? assignments found dst)
            (BackendPhiSourceTemp)
            source)]
        [_ source])]
    [(BackendPhiSourceTemp) source]))

(define (compiler-backend-phi-copy-list-replace-source-home
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]
  [dst-home-var : i64]) : CompilerBackendPhiCopyList
  (match copies
    [(BackendPhiCopyNil) BackendPhiCopyNil]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy dst source ty)
          (BackendPhiCopyCons
            (BackendPhiCopy
              dst
              (compiler-backend-phi-source-replace-home
                assignments
                source
                dst-home-var)
              ty)
            (compiler-backend-phi-copy-list-replace-source-home
              assignments
              rest
              dst-home-var))])]))

(define (compiler-backend-emit-phi-source-to-var
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [source : CompilerBackendPhiSource]
  [ty : AstType]) : ResultCompilerBackend
  (match source
    [(BackendPhiSourceTemp)
      (OkCompilerBackend
        (compiler-backend-emit-store-var-with-plan assignments dst "%r11"))]
    [(BackendPhiSourceValue value)
      (if (compiler-backend-phi-same-home? assignments dst value)
        (OkCompilerBackend "")
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          value
          ty)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  (if (compiler-backend-f64-type? ty)
                    "%xmm0"
                    "%rax")
                  ty)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

(define (compiler-backend-emit-phi-copy-item
  [assignments : CompilerRegAssignmentList]
  [copy : CompilerBackendPhiCopy]) : ResultCompilerBackend
  (match copy
    [(BackendPhiCopy dst source ty)
      (compiler-backend-emit-phi-source-to-var assignments dst source ty)]))

(define (compiler-backend-emit-phi-copy-list
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]) : ResultCompilerBackend
  (match copies
    [(BackendPhiCopyNil) (OkCompilerBackend "")]
    [(BackendPhiCopyCons first _)
      (match (compiler-backend-phi-copy-list-find-unblocked
        assignments
        copies
        copies)
        [(BackendSomePhiCopy copy)
          (match copy
            [(BackendPhiCopy dst _ _)
              (match (compiler-backend-emit-phi-copy-item assignments copy)
                [(OkCompilerBackend head)
                  (match (compiler-backend-emit-phi-copy-list
                    assignments
                    (compiler-backend-phi-copy-list-remove-dst copies dst))
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend (string-append head tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(BackendNoPhiCopy)
          (match first
            [(BackendPhiCopy dst source ty)
              (let
                [save : String
                  (compiler-backend-emit-load-var-with-plan
                    assignments
                    dst
                    "%r11")]
                (match (compiler-backend-emit-phi-source-to-var
                  assignments
                  dst
                  source
                  ty)
                  [(OkCompilerBackend head)
                    (match (compiler-backend-emit-phi-copy-list
                      assignments
                      (compiler-backend-phi-copy-list-replace-source-home
                        assignments
                        (compiler-backend-phi-copy-list-remove-dst copies dst)
                        dst))
                      [(OkCompilerBackend tail)
                        (OkCompilerBackend
                          (string-append save (string-append head tail)))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)]))])])]))

(define (compiler-backend-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrList]
  [from-label : String]) : ResultBackendPhiCopies
  (match instrs
    [(IrInstrNil) (OkBackendPhiCopies BackendPhiCopyNil)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi dst inputs ty)
          (match (compiler-backend-phi-input-value inputs from-label)
            [(OkBackendValue value)
              (match (compiler-backend-leading-phi-copies
                assignments
                rest
                from-label)
                [(OkBackendPhiCopies tail)
                  (if (compiler-backend-phi-same-home? assignments dst value)
                    (OkBackendPhiCopies tail)
                    (OkBackendPhiCopies
                      (BackendPhiCopyCons
                        (BackendPhiCopy dst (BackendPhiSourceValue value) ty)
                        tail)))]
                [(ErrBackendPhiCopies message) (ErrBackendPhiCopies message)])]
            [(ErrBackendValue message) (ErrBackendPhiCopies message)])]
        [_ (OkBackendPhiCopies BackendPhiCopyNil)])]))

(define (compiler-backend-emit-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrList]
  [from-label : String]) : ResultCompilerBackend
  (match (compiler-backend-leading-phi-copies assignments instrs from-label)
    [(OkBackendPhiCopies copies)
      (compiler-backend-emit-phi-copy-list assignments copies)]
    [(ErrBackendPhiCopies message)
      (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))

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
  [vars : i64]
  [ret-ty : AstType]) : ResultCompilerBackend
  (match value
    [(IrNoValue)
      (OkCompilerBackend
        (string-append
          "    movq $0, %rax\n"
          (string-append
            (compiler-backend-emit-restore-callee-regs assignments vars)
            "    movq %rbp, %rsp\n    popq %rbp\n    ret\n")))]
    [(IrSomeValue v)
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        v
        ret-ty)
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
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [instr : CompilerIrInstr]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [instr-diag : CompilerDiagnostic
      (compiler-backend-instr-diagnostic
        spans
        source-function
        instr
        func-diag
        "")]
    (match instr
      [(IrInstrMov dst src ty)
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          src
          ty)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  (if (compiler-backend-f64-type? ty)
                    "%xmm0"
                    "%rax")
                  ty)))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrAlloc _ _) (OkCompilerBackend "")]
      [(IrInstrAddrOf dst src)
        (match (compiler-backend-emit-addr-of assignments dst src)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrGep dst base offset elem-ty)
        (match (compiler-backend-emit-gep assignments dst base offset elem-ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrLoad dst src ty)
        (match (compiler-backend-emit-load-instr assignments dst src ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrStorePtr dst src ty)
        (match (compiler-backend-emit-store-ptr assignments dst src ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBoundsCheck index length ok-label)
        (match (compiler-backend-emit-bounds-check
          target
          function
          assignments
          index
          length
          ok-label
          plan
          functions
          externs)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrCast dst src from-ty to-ty)
        (match (compiler-backend-emit-cast assignments dst src from-ty to-ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBinOp dst op lhs rhs ty)
        (match (compiler-backend-emit-binop types assignments dst op lhs rhs ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrUnOp dst op src ty)
        (match (compiler-backend-emit-unop assignments dst op src ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrLaneId _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrSplat _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrVectorBinOp _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrVectorReduce _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrVectorCompare _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrMaskBinOp _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrMaskNot _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrMaskReduce _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrSelect _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrVectorLoad _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrVectorStore _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrPredicatedStore _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrPredicatedLoad _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrTailMask _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrCall dst name args ty)
        (let
          [param-types : AstTypeList
            (compiler-backend-call-param-types name functions externs)]
          (let
            [call-space : i64
              (compiler-backend-call-arg-space target args param-types)]
            (match (compiler-backend-emit-call-args
              target
              assignments
              args
              param-types
              0
              0
              0
              0
              instr-diag)
              [(OkCompilerBackend args-asm)
                (OkCompilerBackend
                  (string-append
                    (compiler-backend-emit-call-space-sub call-space)
                    (string-append
                      args-asm
                      (backend-cat5
                        "    call "
                        (compiler-backend-call-symbol
                          name
                          plan
                          functions
                          externs)
                        "\n"
                        (string-append
                          (compiler-backend-emit-call-space-add call-space)
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            dst
                            (if (compiler-backend-f64-type? ty)
                              "%xmm0"
                              "%rax")
                            ty))
                        ""))))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])))]
      [(IrInstrStore name value ty)
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          value
          ty)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (if (compiler-backend-f64-type? ty)
                  (backend-cat4
                    "    movsd %xmm0, "
                    (compiler-backend-user-symbol name)
                    "(%rip)\n"
                    "")
                  (backend-cat4
                    "    movq %rax, "
                    (compiler-backend-user-symbol name)
                    "(%rip)\n"
                    ""))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
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
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBranch cond true-label false-label)
        (match (compiler-backend-emit-branch
          assignments
          function
          cond
          true-label
          false-label)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrReturn value)
        (match (compiler-backend-emit-return value assignments vars ret-ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrPhi _ _ _) (OkCompilerBackend "")])))

(define (compiler-backend-emit-instrs
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
      (match (compiler-backend-emit-instr
        target
        function
        source-function
        blocks
        current-label
        instr
        assignments
        vars
        types
        ret-ty
        plan
        functions
        externs
        spans
        func-diag)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-instrs
            target
            function
            source-function
            blocks
            current-label
            rest
            assignments
            vars
            types
            ret-ty
            plan
            functions
            externs
            spans
            func-diag)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-block
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [block : CompilerIrBlock]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match block
    [(IrBlock label instrs)
      (match (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        label
        instrs
        assignments
        vars
        types
        ret-ty
        plan
        functions
        externs
        spans
        func-diag)
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
  [source-function : String]
  [all-blocks : CompilerIrBlockList]
  [blocks : CompilerIrBlockList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
      (match (compiler-backend-emit-block
        target
        function
        source-function
        all-blocks
        block
        assignments
        vars
        types
        ret-ty
        plan
        functions
        externs
        spans
        func-diag)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-blocks
            target
            function
            source-function
            all-blocks
            rest
            assignments
            vars
            types
            ret-ty
            plan
            functions
            externs
            spans
            func-diag)
            [(OkCompilerBackend tail)
              (OkCompilerBackend (string-append head tail))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

;; Move INCOMING parameters into their local frame slots (#750). Register
;; params come from rdi/rsi/.. (or xmm0..) per the calling convention; params
;; beyond a bank's registers are read back from the caller's stack frame at
;; `compiler-backend-incoming-stack-arg-offset`, indexed by a sequential
;; stack-param counter that mirrors the call site.
(define (compiler-backend-emit-param-spills
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [params : CompilerIrParamList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]) : ResultCompilerBackend
  (match params
    [(IrParamNil) (OkCompilerBackend "")]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty var-id)
          (let
            [is-f64 : bool (compiler-backend-f64-type? ty)]
            (let
              [next-int : i64
                (if is-f64
                  int-idx
                  (+ int-idx 1))]
              [next-float : i64
                (if is-f64
                  (+ float-idx 1)
                  float-idx)]
              (if (compiler-backend-stack-call-arg-for-banks?
                target
                is-f64
                int-idx
                float-idx
                position)
                (match (compiler-backend-emit-param-spills
                  target
                  assignments
                  rest
                  next-int
                  next-float
                  (+ position 1)
                  (+ stack-idx 1))
                  [(OkCompilerBackend tail)
                    (OkCompilerBackend
                      (string-append
                        (if is-f64
                          (backend-cat4
                            "    movsd "
                            (int->string
                              (compiler-backend-incoming-stack-arg-offset
                                target
                                stack-idx))
                            "(%rbp), %xmm0\n"
                            "")
                          (backend-cat4
                            "    movq "
                            (int->string
                              (compiler-backend-incoming-stack-arg-offset
                                target
                                stack-idx))
                            "(%rbp), %rax\n"
                            ""))
                        (string-append
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            var-id
                            (if is-f64
                              "%xmm0"
                              "%rax")
                            ty)
                          tail)))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])
                (match (if is-f64
                  (compiler-backend-target-float-arg-reg
                    target
                    (if (compiler-backend-target-windows? target)
                      position
                      float-idx))
                  (compiler-backend-target-arg-reg
                    target
                    (if (compiler-backend-target-windows? target)
                      position
                      int-idx)))
                  [(OkBackendReg reg)
                    (match (compiler-backend-emit-param-spills
                      target
                      assignments
                      rest
                      next-int
                      next-float
                      (+ position 1)
                      stack-idx)
                      [(OkCompilerBackend tail)
                        (OkCompilerBackend
                          (string-append
                            (compiler-backend-emit-store-typed-var-with-plan
                              assignments
                              var-id
                              reg
                              ty)
                            tail))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrBackendReg _)
                    (ErrCompilerBackend
                      (compiler-diagnostic-at-start
                        ""
                        "backend: too many params"))]))))])]))

(define (compiler-backend-emit-windows-main-argv-capture
  [target : CompilerBackendTarget]
  [name : String]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and (compiler-backend-target-windows? target) (string-eq name "main"))
    (match plan
      [(BackendRuntimePlan
          _
          _
          _
          _
          _
          _
          _
          _
          _
          arg-count
          arg
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _)
        (if (or arg-count arg)
          "    movq %rcx, .L_tl_argc(%rip)
    movq %rdx, .L_tl_argv(%rip)
"
          "")])
    ""))

(define (compiler-backend-emit-function
  [target : CompilerBackendTarget]
  [func : CompilerIrFunction]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
  (match func
    [(IrFunction name params ret-ty vars blocks)
      ;; The provenance fallback diagnostic for this function (#605): backend
      ;; errors raised while emitting its body stamp this function's source span
      ;; (or `1:1` when none was recorded) rather than always `1:1`.
      (let
        [func-diag : CompilerDiagnostic
          (compiler-backend-function-diagnostic spans name "")]
        (let
          [reg-plan : CompilerRegPlan (compiler-reg-plan-function func)]
          (let
            [raw-assignments : CompilerRegAssignmentList
              (compiler-reg-plan-assignments reg-plan)]
            (let
              [assignments : CompilerRegAssignmentList
                (compiler-backend-drop-param-assignments raw-assignments params)]
              [types : CompilerRegVarTypeList
                (compiler-reg-function-var-types func)]
              (match (compiler-backend-emit-param-spills
                target
                assignments
                params
                0
                0
                0
                0)
                [(OkCompilerBackend spills)
                  (let
                    [symbol : String (compiler-backend-user-symbol name)]
                    (match (compiler-backend-emit-blocks
                      target
                      symbol
                      name
                      blocks
                      blocks
                      assignments
                      vars
                      types
                      ret-ty
                      plan
                      functions
                      externs
                      spans
                      func-diag)
                      [(OkCompilerBackend body)
                        (let
                          [frame : i64
                            (compiler-backend-frame-size
                              (compiler-backend-frame-slots vars assignments))]
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
                                  (string-append
                                    (compiler-backend-emit-windows-main-argv-capture
                                      target
                                      name
                                      plan)
                                    (string-append spills body)))
                                "\n")
                              "")))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)]))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))]))

(define (compiler-backend-emit-functions
  [target : CompilerBackendTarget]
  [functions : CompilerIrFunctionList]
  [all-functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend "")]
    [(IrFunctionCons func rest)
      (match (compiler-backend-emit-function
        target
        func
        all-functions
        externs
        plan
        spans)
        [(OkCompilerBackend head)
          (match (compiler-backend-emit-functions
            target
            rest
            all-functions
            externs
            plan
            spans)
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
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings index)
        length)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-collect-value-string strings value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrMaskNot _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string
            (compiler-backend-collect-value-string strings base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings index)
        length)]
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

(define (compiler-backend-collect-value-f64
  [floats : BackendStringList]
  [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueF64 text) (compiler-backend-string-list-add floats text)]
    [_ floats]))

(define (compiler-backend-collect-value-list-f64s
  [floats : BackendStringList]
  [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) floats]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-f64s
        (compiler-backend-collect-value-f64 floats value)
        rest)]))

(define (compiler-backend-collect-phi-f64s
  [floats : BackendStringList]
  [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) floats]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (compiler-backend-collect-phi-f64s
            (compiler-backend-collect-value-f64 floats value)
            rest)])]))

(define (compiler-backend-collect-instr-f64s
  [floats : BackendStringList]
  [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-value-list-f64s floats args)]
    [(IrInstrStore _ value _) (compiler-backend-collect-value-f64 floats value)]
    [(IrInstrBranch cond _ _) (compiler-backend-collect-value-f64 floats cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) floats]
        [(IrSomeValue value) (compiler-backend-collect-value-f64 floats value)])]
    [(IrInstrPhi _ inputs _) (compiler-backend-collect-phi-f64s floats inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats base)
        offset)]
    [(IrInstrLoad _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats dst)
        src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats index)
        length)]
    [(IrInstrCast _ src _ _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-collect-value-f64 floats value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrMaskNot _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64
            (compiler-backend-collect-value-f64 floats base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats index)
        length)]
    [_ floats]))

(define (compiler-backend-collect-instr-list-f64s
  [floats : BackendStringList]
  [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) floats]
    [(IrInstrCons instr rest)
      (compiler-backend-collect-instr-list-f64s
        (compiler-backend-collect-instr-f64s floats instr)
        rest)]))

(define (compiler-backend-collect-block-f64s
  [floats : BackendStringList]
  [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) floats]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-collect-block-f64s
            (compiler-backend-collect-instr-list-f64s floats instrs)
            rest)])]))

(define (compiler-backend-collect-function-f64s
  [floats : BackendStringList]
  [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) floats]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-backend-collect-function-f64s
            (compiler-backend-collect-block-f64s floats blocks)
            rest)])]))

(define (compiler-backend-collect-global-f64s
  [floats : BackendStringList]
  [globals : CompilerIrGlobalList]) : BackendStringList
  (match globals
    [(IrGlobalNil) floats]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal _ _ value)
          (compiler-backend-collect-global-f64s
            (compiler-backend-collect-value-f64 floats value)
            rest)])]))

(define (compiler-backend-collect-program-f64s [program : CompilerIrProgram]) : BackendStringList
  (match program
    [(IrProgram globals functions _)
      (compiler-backend-collect-function-f64s
        (compiler-backend-collect-global-f64s BackendStringNil globals)
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

(define (compiler-backend-emit-f64-entry [text : String]) : String
  (backend-cat5
    (compiler-backend-f64-label text)
    ":\n    .double "
    text
    "\n"
    ""))

(define (compiler-backend-emit-f64-entries [floats : BackendStringList]) : String
  (match floats
    [(BackendStringNil) ""]
    [(BackendStringCons text rest)
      (string-append
        (compiler-backend-emit-f64-entry text)
        (compiler-backend-emit-f64-entries rest))]))

(define (compiler-backend-emit-f64-rodata [floats : BackendStringList]) : String
  (match floats
    [(BackendStringNil) ""]
    [_
      (string-append
        "    .section .rodata\n"
        (compiler-backend-emit-f64-entries floats))]))

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
    [(IrValueF64 text)
      (OkCompilerBackend (backend-cat3 "    .double " text "\n"))]
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
          (let
            [symbol : String (compiler-backend-user-symbol name)]
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
    [(IrInstrBoundsCheck _ _ _) (string-eq name "tl_oob_abort")]
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

(define (compiler-backend-provides-runtime-name?
  [name : String]
  [candidate : String]
  [enabled : bool]) : bool
  (and (string-eq name candidate) enabled))

(define (compiler-backend-plan-provides?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        provides-string-eq
        provides-string-to-int
        provides-int-to-string
        provides-abort
        provides-print-err
        provides-arg-count
        provides-arg
        provides-read-file
        provides-write-file
        provides-file-exists
        provides-file-read-chunk
        provides-process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances)
      (or
        (backend-or8
          (compiler-backend-provides-runtime-name? name "tl_alloc" alloc)
          (compiler-backend-provides-runtime-name?
            name
            "tl_region_mark"
            region-mark)
          (compiler-backend-provides-runtime-name?
            name
            "tl_region_reset"
            region-reset)
          (compiler-backend-provides-runtime-name? name "tl_oob_abort" oob)
          (compiler-backend-provides-runtime-name?
            name
            "tl_substring"
            substring)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_concat"
            concat)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_eq"
            provides-string-eq)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_to_int"
            provides-string-to-int))
        (or
          (backend-or8
            (compiler-backend-provides-runtime-name?
              name
              "tl_int_to_string"
              provides-int-to-string)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_abort"
              provides-abort)
            (compiler-backend-provides-runtime-name?
              name
              "tl_print_err"
              provides-print-err)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_arg_count"
              provides-arg-count)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_arg"
              provides-arg)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_read_file"
              provides-read-file)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_write_file"
              provides-write-file)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_file_exists"
              provides-file-exists))
          (or
            (backend-or8
              (compiler-backend-provides-runtime-name?
                name
                "tl_process_output"
                provides-process-output)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_read_file_status"
                provides-read-file)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_write_file_status"
                provides-write-file)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_append_file_status"
                provides-write-file)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_file_exists_status"
                provides-file-exists)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_file_read_chunk_status"
                provides-file-read-chunk)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_file_read_chunk_bytes"
                provides-file-read-chunk)
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_file_read_chunk_eof"
                provides-file-read-chunk))
            (or
              (compiler-backend-provides-runtime-name?
                name
                ".L_tl_read_stdin_line"
                read-line)
              (or
                (backend-or4
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_read_stdin_bytes"
                    read-bytes)
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_stdin_eof"
                    stdin-eof)
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_flush_stdout"
                    flush-stdout)
                  (compiler-backend-provides-runtime-name?
                    name
                    "tl_random_system_seed"
                    random-system-seed))
                (compiler-backend-provides-runtime-name?
                  name
                  "tl_windows_setup_instances"
                  windows-setup-instances))))))]))

(define (compiler-backend-runtime-plan-for
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultBackendRuntimePlan
  (let
    [defines-alloc : bool
      (compiler-backend-function-list-defines? functions "tl_alloc")]
    [defines-oob : bool
      (compiler-backend-function-list-defines? functions "tl_oob_abort")]
    [defines-substring : bool
      (compiler-backend-function-list-defines? functions "tl_substring")]
    [defines-concat : bool
      (compiler-backend-function-list-defines? functions "tl_string_concat")]
    [defines-string-eq : bool
      (compiler-backend-function-list-defines? functions "tl_string_eq")]
    [defines-string-to-int : bool
      (compiler-backend-function-list-defines? functions "tl_string_to_int")]
    [defines-int-to-string : bool
      (compiler-backend-function-list-defines? functions "tl_int_to_string")]
    [defines-print-err : bool
      (compiler-backend-function-list-defines? functions "tl_print_err")]
    [defines-region-mark : bool
      (compiler-backend-function-list-defines? functions "tl_region_mark")]
    [defines-region-reset : bool
      (compiler-backend-function-list-defines? functions "tl_region_reset")]
    [defines-process-output : bool
      (compiler-backend-function-list-defines? functions "tl_process_output")]
    [defines-random-system-seed : bool
      (compiler-backend-function-list-defines?
        functions
        "tl_random_system_seed")]
    [defines-windows-setup-instances : bool
      (compiler-backend-function-list-defines?
        functions
        "tl_windows_setup_instances")]
    [extern-alloc : bool
      (compiler-backend-extern-list-references? externs "tl_alloc")]
    [extern-oob : bool
      (compiler-backend-extern-list-references? externs "tl_oob_abort")]
    [extern-substring : bool
      (compiler-backend-extern-list-references? externs "tl_substring")]
    [extern-concat : bool
      (compiler-backend-extern-list-references? externs "tl_string_concat")]
    [extern-string-eq : bool
      (compiler-backend-extern-list-references? externs "tl_string_eq")]
    [extern-string-to-int : bool
      (compiler-backend-extern-list-references? externs "tl_string_to_int")]
    [extern-int-to-string : bool
      (compiler-backend-extern-list-references? externs "tl_int_to_string")]
    [extern-abort : bool
      (compiler-backend-extern-list-references? externs ".L_tl_abort")]
    [extern-print-err : bool
      (compiler-backend-extern-list-references? externs "tl_print_err")]
    [extern-arg-count : bool
      (compiler-backend-extern-list-references? externs ".L_tl_arg_count")]
    [extern-arg : bool
      (compiler-backend-extern-list-references? externs ".L_tl_arg")]
    [extern-read-file : bool
      (compiler-backend-extern-list-references? externs ".L_tl_read_file")]
    [extern-write-file : bool
      (compiler-backend-extern-list-references? externs ".L_tl_write_file")]
    [extern-file-exists : bool
      (compiler-backend-extern-list-references? externs ".L_tl_file_exists")]
    [extern-read-file-status : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_read_file_status")]
    [extern-write-file-status : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_write_file_status")]
    [extern-append-file-status : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_append_file_status")]
    [extern-file-exists-status : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_file_exists_status")]
    [extern-file-read-chunk-status : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_file_read_chunk_status")]
    [extern-file-read-chunk-bytes : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_file_read_chunk_bytes")]
    [extern-file-read-chunk-eof : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_file_read_chunk_eof")]
    [extern-read-line : bool
      (compiler-backend-extern-list-references? externs ".L_tl_read_stdin_line")]
    [extern-read-bytes : bool
      (compiler-backend-extern-list-references?
        externs
        ".L_tl_read_stdin_bytes")]
    [extern-stdin-eof : bool
      (compiler-backend-extern-list-references? externs ".L_tl_stdin_eof")]
    [extern-flush-stdout : bool
      (compiler-backend-extern-list-references? externs ".L_tl_flush_stdout")]
    [extern-process-output : bool
      (compiler-backend-extern-list-references? externs "tl_process_output")]
    [extern-region-mark : bool
      (compiler-backend-extern-list-references? externs "tl_region_mark")]
    [extern-region-reset : bool
      (compiler-backend-extern-list-references? externs "tl_region_reset")]
    [extern-random-system-seed : bool
      (compiler-backend-extern-list-references? externs "tl_random_system_seed")]
    [extern-windows-setup-instances : bool
      (compiler-backend-extern-list-references?
        externs
        "tl_windows_setup_instances")]
    [calls-alloc : bool
      (compiler-backend-function-list-calls? functions "tl_alloc")]
    [calls-oob : bool
      (compiler-backend-function-list-calls? functions "tl_oob_abort")]
    [calls-substring : bool
      (compiler-backend-function-list-calls? functions "tl_substring")]
    [calls-concat : bool
      (compiler-backend-function-list-calls? functions "tl_string_concat")]
    [calls-string-eq : bool
      (compiler-backend-function-list-calls? functions "tl_string_eq")]
    [calls-string-to-int : bool
      (compiler-backend-function-list-calls? functions "tl_string_to_int")]
    [calls-int-to-string : bool
      (compiler-backend-function-list-calls? functions "tl_int_to_string")]
    [calls-abort : bool
      (compiler-backend-function-list-calls? functions ".L_tl_abort")]
    [calls-print-err : bool
      (compiler-backend-function-list-calls? functions "tl_print_err")]
    [calls-arg-count : bool
      (compiler-backend-function-list-calls? functions ".L_tl_arg_count")]
    [calls-arg : bool
      (compiler-backend-function-list-calls? functions ".L_tl_arg")]
    [calls-read-file : bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_file")]
    [calls-write-file : bool
      (compiler-backend-function-list-calls? functions ".L_tl_write_file")]
    [calls-file-exists : bool
      (compiler-backend-function-list-calls? functions ".L_tl_file_exists")]
    [calls-read-file-status : bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_file_status")]
    [calls-write-file-status : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_write_file_status")]
    [calls-append-file-status : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_append_file_status")]
    [calls-file-exists-status : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_file_exists_status")]
    [calls-file-read-chunk-status : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_file_read_chunk_status")]
    [calls-file-read-chunk-bytes : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_file_read_chunk_bytes")]
    [calls-file-read-chunk-eof : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_file_read_chunk_eof")]
    [calls-read-line : bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_stdin_line")]
    [calls-read-bytes : bool
      (compiler-backend-function-list-calls? functions ".L_tl_read_stdin_bytes")]
    [calls-stdin-eof : bool
      (compiler-backend-function-list-calls? functions ".L_tl_stdin_eof")]
    [calls-flush-stdout : bool
      (compiler-backend-function-list-calls? functions ".L_tl_flush_stdout")]
    [calls-process-output : bool
      (compiler-backend-function-list-calls? functions "tl_process_output")]
    [calls-region-mark : bool
      (compiler-backend-function-list-calls? functions "tl_region_mark")]
    [calls-region-reset : bool
      (compiler-backend-function-list-calls? functions "tl_region_reset")]
    [calls-random-system-seed : bool
      (compiler-backend-function-list-calls? functions "tl_random_system_seed")]
    [calls-windows-setup-instances : bool
      (compiler-backend-function-list-calls?
        functions
        "tl_windows_setup_instances")]
    (let
      [needs-oob : bool (and (not defines-oob) (or extern-oob calls-oob))]
      [needs-substring : bool
        (and (not defines-substring) (or extern-substring calls-substring))]
      [needs-concat : bool
        (and (not defines-concat) (or extern-concat calls-concat))]
      [needs-string-eq : bool
        (and (not defines-string-eq) (or extern-string-eq calls-string-eq))]
      [needs-string-to-int : bool
        (and
          (not defines-string-to-int)
          (or extern-string-to-int calls-string-to-int))]
      [needs-int-to-string : bool
        (and
          (not defines-int-to-string)
          (or extern-int-to-string calls-int-to-string))]
      [direct-abort : bool (or extern-abort calls-abort)]
      [needs-print-err : bool
        (and (not defines-print-err) (or extern-print-err calls-print-err))]
      [needs-arg-count : bool (or extern-arg-count calls-arg-count)]
      [needs-arg : bool (or extern-arg calls-arg)]
      [needs-read-file : bool
        (or
          (or extern-read-file calls-read-file)
          (or extern-read-file-status calls-read-file-status))]
      [needs-write-file : bool
        (or
          (or extern-write-file calls-write-file)
          (or
            (or extern-write-file-status calls-write-file-status)
            (or extern-append-file-status calls-append-file-status)))]
      [needs-file-exists : bool
        (or
          (or extern-file-exists calls-file-exists)
          (or extern-file-exists-status calls-file-exists-status))]
      [needs-file-read-chunk : bool
        (or
          (or extern-file-read-chunk-status calls-file-read-chunk-status)
          (or
            extern-file-read-chunk-bytes
            (or
              calls-file-read-chunk-bytes
              (or extern-file-read-chunk-eof calls-file-read-chunk-eof))))]
      [needs-read-line : bool (or extern-read-line calls-read-line)]
      [needs-read-bytes : bool (or extern-read-bytes calls-read-bytes)]
      [needs-stdin-eof : bool (or extern-stdin-eof calls-stdin-eof)]
      [needs-flush-stdout : bool (or extern-flush-stdout calls-flush-stdout)]
      [needs-process-output : bool
        (and
          (not defines-process-output)
          (or extern-process-output calls-process-output))]
      [needs-region-mark : bool
        (and
          (not defines-region-mark)
          (or extern-region-mark calls-region-mark))]
      [needs-region-reset : bool
        (and
          (not defines-region-reset)
          (or extern-region-reset calls-region-reset))]
      [needs-random-system-seed : bool
        (and
          (not defines-random-system-seed)
          (or extern-random-system-seed calls-random-system-seed))]
      [needs-windows-setup-instances : bool
        (and
          (not defines-windows-setup-instances)
          (or extern-windows-setup-instances calls-windows-setup-instances))]
      [direct-alloc : bool
        (and (not defines-alloc) (or extern-alloc calls-alloc))]
      (let
        [needs-abort : bool
          (or
            direct-abort
            (or
              needs-arg
              (or needs-read-file (or needs-write-file needs-file-exists))))]
        [needs-alloc : bool
          (or
            (backend-or8
              direct-alloc
              needs-int-to-string
              needs-substring
              needs-concat
              needs-arg
              needs-read-file
              needs-write-file
              needs-file-exists)
            (or
              needs-file-read-chunk
              (or
                needs-process-output
                (or
                  needs-read-line
                  (or
                    needs-read-bytes
                    (or needs-random-system-seed needs-windows-setup-instances))))))]
        (OkBackendRuntimePlan
          (BackendRuntimePlan
            needs-alloc
            needs-oob
            needs-substring
            needs-concat
            needs-string-eq
            needs-string-to-int
            needs-int-to-string
            needs-abort
            needs-print-err
            needs-arg-count
            needs-arg
            needs-read-file
            needs-write-file
            needs-file-exists
            needs-file-read-chunk
            needs-process-output
            needs-read-line
            needs-read-bytes
            needs-stdin-eof
            needs-flush-stdout
            needs-region-mark
            needs-region-reset
            needs-random-system-seed
            needs-windows-setup-instances))))))

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

(define (compiler-backend-runtime-alloc-data-for-target
  [target : CompilerBackendTarget]) : String
  (string-append
    (if (compiler-backend-target-windows? target)
      ""
      "    .section .bss
    .balign 8
tl_current_arena:
    .zero 8

")
    "    .section .rodata
.L_tl_alloc_msg:
    .byte 116,108,58,32,97,108,108,111,99,97,116,105,111,110,32,102,97,105,108,101,100,10
    .set .L_tl_alloc_msg_len, . - .L_tl_alloc_msg

"))

(define (compiler-backend-runtime-arena-data-for-target
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    ""
    "    .section .bss
    .balign 8
tl_current_arena:
    .zero 8

"))

(define (compiler-backend-runtime-region-reset-data) : String
  "    .section .rodata
.L_tl_region_reset_msg:
    .byte 116,108,58,32,105,110,118,97,108,105,100,32,114,101,103,105,111,110,32,109,97,114,107,10
    .set .L_tl_region_reset_msg_len, . - .L_tl_region_reset_msg

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

(define (compiler-backend-runtime-argv-data [arg-count : bool] [arg : bool]) : String
  (if (or arg-count arg)
    (string-append
      "    .data
    .balign 8
.L_tl_argc:
    .quad 0
.L_tl_argv:
    .quad 0

"
      (if arg
        "    .section .rodata
.L_tl_arg_oob_msg:
    .ascii \"tl: argv index out of bounds\\n\"
    .set .L_tl_arg_oob_msg_len, . - .L_tl_arg_oob_msg

"
        ""))
    ""))

(define (compiler-backend-runtime-read-file-data [read-file : bool]) : String
  (if read-file
    "    .section .rodata
.L_tl_read_file_error_msg:
    .ascii \"tl: read-file failed\\n\"
    .set .L_tl_read_file_error_msg_len, . - .L_tl_read_file_error_msg

"
    ""))

(define (compiler-backend-runtime-write-file-data [write-file : bool]) : String
  (if write-file
    "    .section .rodata
.L_tl_write_file_error_msg:
    .ascii \"tl: write-file failed\\n\"
    .set .L_tl_write_file_error_msg_len, . - .L_tl_write_file_error_msg

"
    ""))

(define (compiler-backend-runtime-file-exists-data [file-exists : bool]) : String
  (if file-exists
    "    .section .rodata
.L_tl_file_exists_error_msg:
    .ascii \"tl: file-exists? failed\\n\"
    .set .L_tl_file_exists_error_msg_len, . - .L_tl_file_exists_error_msg

"
    ""))

(define (compiler-backend-runtime-file-read-chunk-data
  [target : CompilerBackendTarget]
  [file-read-chunk : bool]) : String
  (if (and file-read-chunk (not (compiler-backend-target-windows? target)))
    "    .data
    .balign 8
.L_tl_file_handle_next:
    .quad 1
    .section .bss
    .balign 8
.L_tl_file_handle_fds:
    .zero 8192
.L_tl_file_handle_modes:
    .zero 8192
.L_tl_file_handle_states:
    .zero 8192
.L_tl_file_handle_eofs:
    .zero 8192
.L_tl_file_handle_last_ptrs:
    .zero 8192
.L_tl_file_handle_last_lens:
    .zero 8192
.L_tl_file_handle_last_eofs:
    .zero 8192

"
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

(define (compiler-backend-runtime-process-output-data
  [target : CompilerBackendTarget]
  [process-output : bool]) : String
  (if process-output
    (string-append
      (if (compiler-backend-target-windows? target)
        ""
        "    .data
    .balign 8
.L_tl_envp:
    .quad 0

")
      "    .section .rodata
.L_tl_process_unsupported_msg:
    .ascii \"process: runtime execution is not supported on this target\"
    .set .L_tl_process_unsupported_msg_len, . - .L_tl_process_unsupported_msg
.L_tl_process_spawn_msg:
    .ascii \"process: spawn failed\"
    .set .L_tl_process_spawn_msg_len, . - .L_tl_process_spawn_msg
.L_tl_process_wait_msg:
    .ascii \"process: wait failed\"
    .set .L_tl_process_wait_msg_len, . - .L_tl_process_wait_msg
.L_tl_process_exec_marker:
    .ascii \"exec\"
    .set .L_tl_process_exec_marker_len, . - .L_tl_process_exec_marker
.L_tl_process_stdout_name:
    .ascii \"typelisp-process-stdout\"
    .byte 0
.L_tl_process_stderr_name:
    .ascii \"typelisp-process-stderr\"
    .byte 0

")
    ""))

(define (compiler-backend-runtime-random-system-seed-data
  [random-system-seed : bool]) : String
  (if random-system-seed
    "    .section .rodata
.L_tl_random_system_seed_err_msg:
    .ascii \"random: system entropy unavailable\"
    .set .L_tl_random_system_seed_err_msg_len, . - .L_tl_random_system_seed_err_msg

"
    ""))

(define (compiler-backend-runtime-windows-setup-instances-data
  [windows-setup-instances : bool]) : String
  (if windows-setup-instances
    "    .section .rodata
.L_tl_windows_setup_unsupported_msg:
    .ascii \"windows setup: SetupConfiguration is only supported on windows-x86_64 targets\"
    .set .L_tl_windows_setup_unsupported_msg_len, . - .L_tl_windows_setup_unsupported_msg
.L_tl_windows_setup_unavailable_msg:
    .ascii \"windows setup: SetupConfiguration COM server is unavailable\"
    .set .L_tl_windows_setup_unavailable_msg_len, . - .L_tl_windows_setup_unavailable_msg

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
        _
        _
        _
        _
        _
        arg-count
        arg
        read-file
        write-file
        file-exists
        file-read-chunk
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances)
      (string-append
        (if alloc
          (compiler-backend-runtime-alloc-data-for-target target)
          (if (or region-mark region-reset)
            (compiler-backend-runtime-arena-data-for-target target)
            ""))
        (string-append
          (if oob
            (compiler-backend-runtime-oob-data)
            "")
          (string-append
            (if region-reset
              (compiler-backend-runtime-region-reset-data)
              "")
            (string-append
              (compiler-backend-runtime-argv-data arg-count arg)
              (string-append
                (compiler-backend-runtime-read-file-data read-file)
                (string-append
                  (compiler-backend-runtime-write-file-data write-file)
                  (string-append
                    (compiler-backend-runtime-file-exists-data file-exists)
                    (string-append
                      (compiler-backend-runtime-file-read-chunk-data
                        target
                        file-read-chunk)
                      (string-append
                        (compiler-backend-runtime-process-output-data
                          target
                          process-output)
                        (string-append
                          (compiler-backend-runtime-stdio-data
                            read-line
                            read-bytes
                            stdin-eof)
                          (string-append
                            (compiler-backend-runtime-flush-stdout-data
                              target
                              flush-stdout)
                            (string-append
                              (compiler-backend-runtime-random-system-seed-data
                                random-system-seed)
                              (compiler-backend-runtime-windows-setup-instances-data
                                windows-setup-instances)))))))))))))]))

(define (compiler-backend-runtime-alloc-functions) : String
  "    .globl tl_alloc
tl_alloc:
    addq $7, %rdi
    jc .L_tl_alloc_abort
    andq $-8, %rdi
    movq %rdi, %rsi
    movq tl_current_arena(%rip), %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena
    movq 16(%r8), %rax
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_new_arena
    movq %rcx, 16(%r8)
    ret
.L_tl_alloc_new_arena:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $32, %rcx
    jc .L_tl_alloc_abort
    cmpq %rdx, %rcx
    jbe .L_tl_alloc_len_ready
    movq %rcx, %rdx
.L_tl_alloc_len_ready:
    push %rdx
    push %rsi
    movq %rdx, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    pop %rsi
    pop %rdx
    testq %rax, %rax
    js .L_tl_alloc_abort
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq tl_current_arena(%rip), %r8
    movq %r8, 0(%rax)
    leaq 32(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, tl_current_arena(%rip)
    movq %r8, %rax
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

(define (compiler-backend-runtime-region-mark-functions) : String
  "    .globl tl_region_mark
tl_region_mark:
    movq tl_current_arena(%rip), %rax
    testq %rax, %rax
    jz .L_tl_region_mark_zero
    movq 16(%rax), %rax
    ret
.L_tl_region_mark_zero:
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-region-reset-functions) : String
  "    .globl tl_region_reset
tl_region_reset:
    push %rbx
    movq %rdi, %rbx
    testq %rbx, %rbx
    jz .L_tl_region_reset_all
    movq tl_current_arena(%rip), %r8
    testq %r8, %r8
    jz .L_tl_region_reset_invalid
.L_tl_region_reset_find:
    movq 8(%r8), %r9
    cmpq %r9, %rbx
    jb .L_tl_region_reset_next
    movq 24(%r8), %r9
    cmpq %r9, %rbx
    jbe .L_tl_region_reset_found
.L_tl_region_reset_next:
    movq 0(%r8), %r8
    testq %r8, %r8
    jnz .L_tl_region_reset_find
    jmp .L_tl_region_reset_invalid
.L_tl_region_reset_found:
    movq tl_current_arena(%rip), %r9
.L_tl_region_reset_drop_newer:
    cmpq %r8, %r9
    je .L_tl_region_reset_restore
    movq 0(%r9), %r10
    movq 24(%r9), %rsi
    subq %r9, %rsi
    movq %r9, %rdi
    push %r8
    push %r10
    movq $11, %rax
    syscall
    pop %r10
    pop %r8
    movq %r10, %r9
    jmp .L_tl_region_reset_drop_newer
.L_tl_region_reset_restore:
    movq %rbx, 16(%r8)
    movq %r8, tl_current_arena(%rip)
    pop %rbx
    ret
.L_tl_region_reset_all:
    movq tl_current_arena(%rip), %r8
    movq $0, tl_current_arena(%rip)
.L_tl_region_reset_all_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_done
    movq 0(%r8), %r9
    movq 24(%r8), %rsi
    subq %r8, %rsi
    movq %r8, %rdi
    push %r9
    movq $11, %rax
    syscall
    pop %r8
    jmp .L_tl_region_reset_all_loop
.L_tl_region_reset_done:
    pop %rbx
    ret
.L_tl_region_reset_invalid:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_region_reset_msg(%rip), %rsi
    movq $.L_tl_region_reset_msg_len, %rdx
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

(define (compiler-backend-runtime-abort-functions) : String
  ".L_tl_abort:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $2, %rdi
    movq $1, %rax
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")

(define (compiler-backend-runtime-print-err-functions) : String
  "    .globl tl_print_err
tl_print_err:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $2, %rdi
    movq $1, %rax
    syscall
    ret

")

(define (compiler-backend-runtime-arg-count-functions) : String
  ".L_tl_arg_count:
    movq .L_tl_argc(%rip), %rax
    ret

")

(define (compiler-backend-runtime-arg-functions) : String
  ".L_tl_arg:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    cmpq $0, %rbx
    jl .L_tl_arg_oob
    movq .L_tl_argc(%rip), %rax
    cmpq %rax, %rbx
    jge .L_tl_arg_oob
    movq .L_tl_argv(%rip), %rax
    movq (%rax,%rbx,8), %rbx
    xorq %r12, %r12
.L_tl_arg_len_loop:
    cmpb $0, (%rbx,%r12)
    je .L_tl_arg_len_done
    incq %r12
    jmp .L_tl_arg_len_loop
.L_tl_arg_len_done:
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_arg_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_arg_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_arg_copy_loop
.L_tl_arg_copy_done:
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
.L_tl_arg_oob:
    leaq .L_tl_arg_oob_msg(%rip), %rdi
    movq $.L_tl_arg_oob_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-read-file-functions) : String
  ".L_tl_read_file:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_read_file_error
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_read_file_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_read_file_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_read_file_path_copy_loop
.L_tl_read_file_path_copy_done:
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_read_file_error
    movq %rax, %rbx
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    movq $2, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    movq %rax, %r12
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    xorq %rax, %rax
    movq %rbx, %rdi
    movq %r13, %rsi
    movq %r12, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    cmpq %r12, %rax
    jne .L_tl_read_file_close_error
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_read_file_error
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
.L_tl_read_file_close_error:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
.L_tl_read_file_error:
    leaq .L_tl_read_file_error_msg(%rip), %rdi
    movq $.L_tl_read_file_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-write-file-functions) : String
  ".L_tl_write_file:
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
    cmpq $0, %r12
    jl .L_tl_write_file_error
    cmpq $0, %r14
    jl .L_tl_write_file_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_write_file_error
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_write_file_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_write_file_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_write_file_path_copy_loop
.L_tl_write_file_path_copy_done:
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $577, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_write_file_error
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_write_file_close_error
    cmpq %r14, %rax
    jne .L_tl_write_file_close_error
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_write_file_error
    xorq %rax, %rax
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_write_file_close_error:
    movq $3, %rax
    movq %r15, %rdi
    syscall
.L_tl_write_file_error:
    leaq .L_tl_write_file_error_msg(%rip), %rdi
    movq $.L_tl_write_file_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-file-exists-functions) : String
  ".L_tl_file_exists:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_file_exists_error
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_file_exists_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_file_exists_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_file_exists_path_copy_loop
.L_tl_file_exists_path_copy_done:
    movb $0, (%r13,%r12)
    movq $21, %rax
    movq %r13, %rdi
    xorq %rsi, %rsi
    syscall
    testq %rax, %rax
    jz .L_tl_file_exists_true
    cmpq $-2, %rax
    je .L_tl_file_exists_false
    jmp .L_tl_file_exists_error
.L_tl_file_exists_true:
    movq $1, %rax
    jmp .L_tl_file_exists_return
.L_tl_file_exists_false:
    xorq %rax, %rax
.L_tl_file_exists_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_file_exists_error:
    leaq .L_tl_file_exists_error_msg(%rip), %rdi
    movq $.L_tl_file_exists_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-read-file-status-functions) : String
  ".L_tl_read_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_read_file_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_read_file_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_read_file_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_read_file_status_path_copy_loop
.L_tl_read_file_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_error_from_rax
    movq %rax, %rbx
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    movq $2, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
    movq %rax, %r13
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
    cmpq $0, %r13
    je .L_tl_read_file_status_close_success
    xorq %rax, %rax
    movq %rbx, %rdi
    leaq -32(%rbp), %rsi
    movq $1, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
.L_tl_read_file_status_close_success:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_invalid:
    movq $22, %rax
.L_tl_read_file_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-write-file-status-functions) : String
  ".L_tl_write_file_status:
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
    cmpq $0, %r12
    jl .L_tl_write_file_status_invalid
    cmpq $0, %r14
    jl .L_tl_write_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_write_file_status_invalid
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_write_file_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_write_file_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_write_file_status_path_copy_loop
.L_tl_write_file_status_path_copy_done:
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $577, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_error_from_rax
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_close_error_from_rax
    cmpq %r14, %rax
    jne .L_tl_write_file_status_short_write
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_short_write:
    movq $5, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_invalid:
    movq $22, %rax
.L_tl_write_file_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-append-file-status-functions) : String
  ".L_tl_append_file_status:
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
    cmpq $0, %r12
    jl .L_tl_append_file_status_invalid
    cmpq $0, %r14
    jl .L_tl_append_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_append_file_status_invalid
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_append_file_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_append_file_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_append_file_status_path_copy_loop
.L_tl_append_file_status_path_copy_done:
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $1089, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_error_from_rax
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_close_error_from_rax
    cmpq %r14, %rax
    jne .L_tl_append_file_status_short_write
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_short_write:
    movq $5, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_invalid:
    movq $22, %rax
.L_tl_append_file_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-exists-status-functions) : String
  ".L_tl_file_exists_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_file_exists_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_file_exists_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_file_exists_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_file_exists_status_path_copy_loop
.L_tl_file_exists_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $21, %rax
    movq %r13, %rdi
    xorq %rsi, %rsi
    syscall
    testq %rax, %rax
    jz .L_tl_file_exists_status_return
    negq %rax
    jmp .L_tl_file_exists_status_return
.L_tl_file_exists_status_invalid:
    movq $22, %rax
.L_tl_file_exists_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-read-chunk-status-functions) : String
  ".L_tl_file_read_chunk_status:
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
    cmpq $0, %r12
    jl .L_tl_file_read_chunk_status_invalid
    cmpq $1, %rbx
    jl .L_tl_file_read_chunk_status_unsupported
    cmpq $1024, %rbx
    jge .L_tl_file_read_chunk_status_unsupported
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $1, %rax
    jne .L_tl_file_read_chunk_status_unsupported
    leaq .L_tl_file_handle_modes(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $0, %rax
    jne .L_tl_file_read_chunk_status_unsupported
    movq %r12, %rdi
    cmpq $0, %rdi
    jg .L_tl_file_read_chunk_status_alloc_ready
    movq $1, %rdi
.L_tl_file_read_chunk_status_alloc_ready:
    call tl_alloc
    movq %rax, %r14
    testq %r12, %r12
    jz .L_tl_file_read_chunk_status_zero
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq (%rcx,%rbx,8), %rdi
    movq %r14, %rsi
    movq %r12, %rdx
    xorq %rax, %rax
    syscall
    testq %rax, %rax
    js .L_tl_file_read_chunk_status_error_from_rax
    movq %rax, %r15
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq %r14, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq %r15, (%rcx,%rbx,8)
    testq %r15, %r15
    jz .L_tl_file_read_chunk_status_eof
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq %rax, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_zero:
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq %r14, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq $0, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq %rax, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_eof:
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq $1, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq $1, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_error_from_rax:
    negq %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_invalid:
    movq $22, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_unsupported:
    movq $38, %rax
.L_tl_file_read_chunk_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-read-chunk-bytes-functions) : String
  ".L_tl_file_read_chunk_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    xorq %r12, %r12
    xorq %r13, %r13
    cmpq $1, %rbx
    jl .L_tl_file_read_chunk_bytes_alloc
    cmpq $1024, %rbx
    jge .L_tl_file_read_chunk_bytes_alloc
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq (%rcx,%rbx,8), %r12
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq (%rcx,%rbx,8), %r13
.L_tl_file_read_chunk_bytes_alloc:
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-read-chunk-eof-functions) : String
  ".L_tl_file_read_chunk_eof:
    movq $1, %rax
    cmpq $1, %rdi
    jl .L_tl_file_read_chunk_eof_return
    cmpq $1024, %rdi
    jge .L_tl_file_read_chunk_eof_return
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq (%rcx,%rdi,8), %rax
.L_tl_file_read_chunk_eof_return:
    ret

")

(define (compiler-backend-runtime-windows-file-read-chunk-functions) : String
  ".L_tl_file_read_chunk_status:
    movq $38, %rax
    ret

.L_tl_file_read_chunk_bytes:
    push %rbp
    mov %rsp, %rbp
    push %r12
    sub $40, %rsp
    movq $1, %rcx
    call tl_alloc
    movq %rax, %r12
    movq $16, %rcx
    call tl_alloc
    movq %r12, 0(%rax)
    movq $0, 8(%rax)
    add $40, %rsp
    pop %r12
    pop %rbp
    ret

.L_tl_file_read_chunk_eof:
    movq $1, %rax
    ret

")

(define (compiler-backend-runtime-file-read-chunk-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-file-read-chunk-functions)
    (string-append
      (compiler-backend-runtime-file-read-chunk-status-functions)
      (string-append
        (compiler-backend-runtime-file-read-chunk-bytes-functions)
        (compiler-backend-runtime-file-read-chunk-eof-functions)))))

(define (compiler-backend-runtime-windows-read-file-functions) : String
  ".L_tl_read_file:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_read_file_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_read_file_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_read_file_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_read_file_path_copy_loop
.L_tl_read_file_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    movq $0x8000, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_error
    movslq %eax, %rbx
    movq %rbx, %rcx
    xorq %rdx, %rdx
    movq $2, %r8
    sub $32, %rsp
    call _lseeki64
    add $32, %rsp
    cmpq $0, %rax
    jl .L_tl_read_file_close_error
    movq %rax, %r12
    movq %rbx, %rcx
    xorq %rdx, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _lseeki64
    add $32, %rsp
    cmpq $0, %rax
    jl .L_tl_read_file_close_error
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %rbx, %rcx
    movq %r13, %rdx
    movq %r12, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    cmpq %r12, %rax
    jne .L_tl_read_file_close_error
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_error
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
.L_tl_read_file_close_error:
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
.L_tl_read_file_error:
    leaq .L_tl_read_file_error_msg(%rip), %rcx
    movq $.L_tl_read_file_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-write-file-functions) : String
  ".L_tl_write_file:
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
    cmpq $0, %r12
    jl .L_tl_write_file_error
    cmpq $0, %r14
    jl .L_tl_write_file_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_write_file_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    xorq %r10, %r10
.L_tl_write_file_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_write_file_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r15,%r10)
    incq %r10
    jmp .L_tl_write_file_path_copy_loop
.L_tl_write_file_path_copy_done:
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8301, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_error
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_write_file_close_error
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_error
    xorq %rax, %rax
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_write_file_close_error:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
.L_tl_write_file_error:
    leaq .L_tl_write_file_error_msg(%rip), %rcx
    movq $.L_tl_write_file_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-file-exists-functions) : String
  ".L_tl_file_exists:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_file_exists_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_file_exists_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_file_exists_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_file_exists_path_copy_loop
.L_tl_file_exists_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    xorq %rdx, %rdx
    sub $32, %rsp
    call _access
    add $32, %rsp
    testl %eax, %eax
    jz .L_tl_file_exists_true
    xorq %rax, %rax
    jmp .L_tl_file_exists_return
.L_tl_file_exists_true:
    movq $1, %rax
.L_tl_file_exists_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_file_exists_error:
    leaq .L_tl_file_exists_error_msg(%rip), %rcx
    movq $.L_tl_file_exists_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-read-file-status-functions) : String
  ".L_tl_read_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_read_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_read_file_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_read_file_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_read_file_status_win_path_copy_loop
.L_tl_read_file_status_win_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    movq $0x8000, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_errno
    movslq %eax, %rbx
    movq %rbx, %rcx
    leaq -32(%rbp), %rdx
    movq $1, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_close_errno
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_read_file_status_win_close_saved
    movq $1, %r12
.L_tl_read_file_status_win_close_saved:
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_read_file_status_win_return
    movq $1, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_invalid:
    movq $22, %rax
.L_tl_read_file_status_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-write-file-status-functions) : String
  ".L_tl_write_file_status:
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
    cmpq $0, %r12
    jl .L_tl_write_file_status_win_invalid
    cmpq $0, %r14
    jl .L_tl_write_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_write_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    xorq %r10, %r10
.L_tl_write_file_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_write_file_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r15,%r10)
    incq %r10
    jmp .L_tl_write_file_status_win_path_copy_loop
.L_tl_write_file_status_win_path_copy_done:
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8301, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_errno
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_close_errno
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_write_file_status_win_short_write
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_short_write:
    movq $5, %r12
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_write_file_status_win_close_saved
    movq $1, %r12
.L_tl_write_file_status_win_close_saved:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_write_file_status_win_return
    movq $1, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_invalid:
    movq $22, %rax
.L_tl_write_file_status_win_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-append-file-status-functions) : String
  ".L_tl_append_file_status:
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
    cmpq $0, %r12
    jl .L_tl_append_file_status_win_invalid
    cmpq $0, %r14
    jl .L_tl_append_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_append_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    xorq %r10, %r10
.L_tl_append_file_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_append_file_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r15,%r10)
    incq %r10
    jmp .L_tl_append_file_status_win_path_copy_loop
.L_tl_append_file_status_win_path_copy_done:
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8109, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_errno
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_close_errno
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_append_file_status_win_short_write
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_short_write:
    movq $5, %r12
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_append_file_status_win_close_saved
    movq $1, %r12
.L_tl_append_file_status_win_close_saved:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_append_file_status_win_return
    movq $1, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_invalid:
    movq $22, %rax
.L_tl_append_file_status_win_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-file-exists-status-functions) : String
  ".L_tl_file_exists_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_file_exists_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_file_exists_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_file_exists_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_file_exists_status_win_path_copy_loop
.L_tl_file_exists_status_win_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    xorq %rdx, %rdx
    sub $32, %rsp
    call _access
    add $32, %rsp
    testl %eax, %eax
    jz .L_tl_file_exists_status_win_success
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_file_exists_status_win_return
    movq $1, %rax
    jmp .L_tl_file_exists_status_win_return
.L_tl_file_exists_status_win_success:
    xorq %rax, %rax
    jmp .L_tl_file_exists_status_win_return
.L_tl_file_exists_status_win_invalid:
    movq $22, %rax
.L_tl_file_exists_status_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

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

(define (compiler-backend-runtime-windows-abort-functions) : String
  ".L_tl_abort:
    push %rbp
    mov %rsp, %rbp
    movq %rdx, %r8
    movq %rcx, %rdx
    movq $2, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit

")

(define (compiler-backend-runtime-windows-print-err-functions) : String
  "    .globl tl_print_err
tl_print_err:
    push %rbp
    mov %rsp, %rbp
    movq %rdx, %r8
    movq %rcx, %rdx
    movq $2, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-arg-count-functions) : String
  ".L_tl_arg_count:
    movq .L_tl_argc(%rip), %rax
    ret

")

(define (compiler-backend-runtime-windows-arg-functions) : String
  ".L_tl_arg:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    cmpq $0, %rbx
    jl .L_tl_arg_oob
    movq .L_tl_argc(%rip), %rax
    cmpq %rax, %rbx
    jge .L_tl_arg_oob
    movq .L_tl_argv(%rip), %rax
    movq (%rax,%rbx,8), %rbx
    xorq %r12, %r12
.L_tl_arg_len_loop:
    cmpb $0, (%rbx,%r12)
    je .L_tl_arg_len_done
    incq %r12
    jmp .L_tl_arg_len_loop
.L_tl_arg_len_done:
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_arg_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_arg_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_arg_copy_loop
.L_tl_arg_copy_done:
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
.L_tl_arg_oob:
    leaq .L_tl_arg_oob_msg(%rip), %rcx
    movq $.L_tl_arg_oob_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-string-eq-functions) : String
  "    .globl tl_string_eq
tl_string_eq:
    cmpq %rcx, %rsi
    jne .L_tl_string_eq_false
.L_tl_string_eq_loop:
    testq %rsi, %rsi
    jz .L_tl_string_eq_true
    movzbl (%rdi), %eax
    movzbl (%rdx), %r8d
    cmpb %r8b, %al
    jne .L_tl_string_eq_false
    incq %rdi
    incq %rdx
    decq %rsi
    jmp .L_tl_string_eq_loop
.L_tl_string_eq_true:
    movq $1, %rax
    ret
.L_tl_string_eq_false:
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-string-to-int-functions) : String
  "    .globl tl_string_to_int
tl_string_to_int:
    xorq %rax, %rax
    xorq %r8, %r8
    testq %rsi, %rsi
    jz .L_tl_string_to_int_done
    movzbl (%rdi), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_int_loop
    movq $1, %r8
    incq %rdi
    decq %rsi
.L_tl_string_to_int_loop:
    testq %rsi, %rsi
    jz .L_tl_string_to_int_apply_sign
    imulq $10, %rax, %rax
    movzbl (%rdi), %ecx
    subq $48, %rcx
    addq %rcx, %rax
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_int_loop
.L_tl_string_to_int_apply_sign:
    testq %r8, %r8
    jz .L_tl_string_to_int_done
    negq %rax
.L_tl_string_to_int_done:
    ret

")

(define (compiler-backend-runtime-windows-string-eq-functions) : String
  "    .globl tl_string_eq
tl_string_eq:
    cmpq %r9, %rdx
    jne .L_tl_string_eq_false
.L_tl_string_eq_loop:
    testq %rdx, %rdx
    jz .L_tl_string_eq_true
    movzbl (%rcx), %eax
    movzbl (%r8), %r10d
    cmpb %r10b, %al
    jne .L_tl_string_eq_false
    incq %rcx
    incq %r8
    decq %rdx
    jmp .L_tl_string_eq_loop
.L_tl_string_eq_true:
    movq $1, %rax
    ret
.L_tl_string_eq_false:
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-windows-string-to-int-functions) : String
  "    .globl tl_string_to_int
tl_string_to_int:
    movq %rcx, %r10
    xorq %rax, %rax
    xorq %r8, %r8
    testq %rdx, %rdx
    jz .L_tl_string_to_int_done
    movzbl (%r10), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_int_loop
    movq $1, %r8
    incq %r10
    decq %rdx
.L_tl_string_to_int_loop:
    testq %rdx, %rdx
    jz .L_tl_string_to_int_apply_sign
    imulq $10, %rax, %rax
    movzbl (%r10), %ecx
    subq $48, %rcx
    addq %rcx, %rax
    incq %r10
    decq %rdx
    jmp .L_tl_string_to_int_loop
.L_tl_string_to_int_apply_sign:
    testq %r8, %r8
    jz .L_tl_string_to_int_done
    negq %rax
.L_tl_string_to_int_done:
    ret

")

(define (compiler-backend-runtime-int-to-string-functions) : String
  "    .globl tl_int_to_string
tl_int_to_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $72, %rsp
    movq %rdi, %rax
    leaq 72(%rsp), %r10
    movq $0, %rcx
    cmpq $0, %rax
    jne .L_tl_int_to_string_nonzero
    decq %r10
    movb $48, (%r10)
    incq %rcx
    jmp .L_tl_int_to_string_digits_done
.L_tl_int_to_string_nonzero:
    movq $0, %r8
    cmpq $0, %rax
    jge .L_tl_int_to_string_abs_ready
    negq %rax
    movq $1, %r8
.L_tl_int_to_string_abs_ready:
    movq $10, %r9
.L_tl_int_to_string_digit_loop:
    xorq %rdx, %rdx
    divq %r9
    addb $48, %dl
    decq %r10
    movb %dl, (%r10)
    incq %rcx
    testq %rax, %rax
    jne .L_tl_int_to_string_digit_loop
    testq %r8, %r8
    jz .L_tl_int_to_string_digits_done
    decq %r10
    movb $45, (%r10)
    incq %rcx
.L_tl_int_to_string_digits_done:
    movq %r10, %rbx
    movq %rcx, %r12
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    movq $0, %rcx
.L_tl_int_to_string_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_int_to_string_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_int_to_string_copy_loop
.L_tl_int_to_string_copy_done:
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $72, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-int-to-string-functions) : String
  "    .globl tl_int_to_string
tl_int_to_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $72, %rsp
    movq %rcx, %rax
    leaq 72(%rsp), %r10
    movq $0, %rcx
    cmpq $0, %rax
    jne .L_tl_int_to_string_nonzero
    decq %r10
    movb $48, (%r10)
    incq %rcx
    jmp .L_tl_int_to_string_digits_done
.L_tl_int_to_string_nonzero:
    movq $0, %r8
    cmpq $0, %rax
    jge .L_tl_int_to_string_abs_ready
    negq %rax
    movq $1, %r8
.L_tl_int_to_string_abs_ready:
    movq $10, %r9
.L_tl_int_to_string_digit_loop:
    xorq %rdx, %rdx
    divq %r9
    addb $48, %dl
    decq %r10
    movb %dl, (%r10)
    incq %rcx
    testq %rax, %rax
    jne .L_tl_int_to_string_digit_loop
    testq %r8, %r8
    jz .L_tl_int_to_string_digits_done
    decq %r10
    movb $45, (%r10)
    incq %rcx
.L_tl_int_to_string_digits_done:
    movq %r10, %rbx
    movq %rcx, %r12
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq $0, %rcx
.L_tl_int_to_string_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_int_to_string_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_int_to_string_copy_loop
.L_tl_int_to_string_copy_done:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $72, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

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

(define (compiler-backend-runtime-windows-process-output-functions) : String
  "tl_process_output:
    leaq .L_tl_process_unsupported_msg(%rip), %rcx
    movq $.L_tl_process_unsupported_msg_len, %rdx
    movq $3, %r8
    jmp .L_tl_process_make_error_win

.L_tl_process_make_error_win:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $40, %rsp
    movq %rcx, %r12
    movq %rdx, %r13
    movq %r8, %rbx
    movq $16, %rcx
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    add $40, %rsp
    pop %r13
    pop %r12
    pop %rbx
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-process-output-functions) : String
  "tl_process_output:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $232, %rsp
    movq %rdi, -8(%rbp)
    movq 0(%rdi), %rdi
    call .L_tl_process_cstring_from_string
    movq %rax, -16(%rbp)
    movq -8(%rbp), %rax
    movq 8(%rax), %r12
    xorq %r13, %r13
.L_tl_process_count_args:
    cmpq $0, 0(%r12)
    je .L_tl_process_count_args_done
    incq %r13
    movq 16(%r12), %r12
    jmp .L_tl_process_count_args
.L_tl_process_count_args_done:
    movq %r13, -24(%rbp)
    leaq 2(%r13), %rdi
    shlq $3, %rdi
    call tl_alloc
    movq %rax, -32(%rbp)
    movq -16(%rbp), %r10
    movq %r10, 0(%rax)
    movq -8(%rbp), %r10
    movq 8(%r10), %r12
    movq -32(%rbp), %r14
    movq $1, %r15
.L_tl_process_fill_argv:
    cmpq $0, 0(%r12)
    je .L_tl_process_fill_argv_done
    movq 8(%r12), %rdi
    call .L_tl_process_cstring_from_string
    movq %rax, (%r14,%r15,8)
    incq %r15
    movq 16(%r12), %r12
    jmp .L_tl_process_fill_argv
.L_tl_process_fill_argv_done:
    movq $0, (%r14,%r15,8)
    leaq .L_tl_process_stdout_name(%rip), %rdi
    xorq %rsi, %rsi
    movq $319, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movq %rax, -40(%rbp)
    leaq .L_tl_process_stderr_name(%rip), %rdi
    xorq %rsi, %rsi
    movq $319, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movq %rax, -56(%rbp)
    leaq -176(%rbp), %rdi
    movq $524288, %rsi
    movq $293, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movslq -176(%rbp), %rax
    movq %rax, -72(%rbp)
    movslq -172(%rbp), %rax
    movq %rax, -80(%rbp)
    movq $57, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    jz .L_tl_process_child
    movq %rax, -88(%rbp)
    movq -80(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -88(%rbp), %rdi
    leaq -184(%rbp), %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    movq $61, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -72(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -112(%rbp)
    movq -72(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -112(%rbp), %rax
    cmpq $0, 8(%rax)
    jne .L_tl_process_spawn_failed
    movq -40(%rbp), %rdi
    call .L_tl_process_seek_start
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -40(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -96(%rbp)
    movq -40(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -56(%rbp), %rdi
    call .L_tl_process_seek_start
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -56(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -104(%rbp)
    movq -56(%rbp), %rdi
    call .L_tl_process_close_fd
    movl -184(%rbp), %eax
    movl %eax, %ecx
    andl $127, %ecx
    cmpl $0, %ecx
    jne .L_tl_process_status_signal
    shrl $8, %eax
    andl $255, %eax
    jmp .L_tl_process_status_ready
.L_tl_process_status_signal:
    movl %ecx, %eax
    addl $128, %eax
.L_tl_process_status_ready:
    movslq %eax, %rdi
    movq -96(%rbp), %rsi
    movq -104(%rbp), %rdx
    call .L_tl_process_make_ok
    jmp .L_tl_process_return
.L_tl_process_child:
    movq -72(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -40(%rbp), %rdi
    movq $1, %rsi
    movq $33, %rax
    syscall
    movq -56(%rbp), %rdi
    movq $2, %rsi
    movq $33, %rax
    syscall
    movq -40(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -56(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -16(%rbp), %rdi
    movq -32(%rbp), %rsi
    movq .L_tl_envp(%rip), %rdx
    movq $59, %rax
    syscall
    movq $1, %rax
    movq -80(%rbp), %rdi
    leaq .L_tl_process_exec_marker(%rip), %rsi
    movq $.L_tl_process_exec_marker_len, %rdx
    syscall
    movq $60, %rax
    movq $127, %rdi
    syscall
.L_tl_process_spawn_failed:
    leaq .L_tl_process_spawn_msg(%rip), %rdi
    movq $.L_tl_process_spawn_msg_len, %rsi
    movq $1, %rdx
    call .L_tl_process_make_error
    jmp .L_tl_process_return
.L_tl_process_wait_failed:
    leaq .L_tl_process_wait_msg(%rip), %rdi
    movq $.L_tl_process_wait_msg_len, %rsi
    movq $2, %rdx
    call .L_tl_process_make_error
.L_tl_process_return:
    addq $232, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_close_fd:
    movq $3, %rax
    syscall
    ret

.L_tl_process_seek_start:
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    movq $8, %rax
    syscall
    ret

.L_tl_process_cstring_from_string:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rdi, %r12
    movq 0(%r12), %r13
    movq 8(%r12), %rbx
    leaq 1(%rbx), %rdi
    call tl_alloc
    movq %rax, %r14
    xorq %rcx, %rcx
.L_tl_process_cstring_copy:
    cmpq %rbx, %rcx
    jge .L_tl_process_cstring_done
    movzbl (%r13,%rcx), %edx
    movb %dl, (%r14,%rcx)
    incq %rcx
    jmp .L_tl_process_cstring_copy
.L_tl_process_cstring_done:
    movb $0, (%r14,%rbx)
    movq %r14, %rax
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_read_all:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $8, %rsp
    movq %rdi, %r12
    movq $4096, %r13
    movq %r13, %rdi
    call tl_alloc
    movq %rax, %r14
    xorq %r15, %r15
.L_tl_process_read_loop:
    movq %r13, %rdx
    subq %r15, %rdx
    cmpq $1024, %rdx
    jl .L_tl_process_read_grow
    movq $0, %rax
    movq %r12, %rdi
    leaq (%r14,%r15), %rsi
    syscall
    testq %rax, %rax
    js .L_tl_process_read_done
    jz .L_tl_process_read_done
    addq %rax, %r15
    jmp .L_tl_process_read_loop
.L_tl_process_read_grow:
    movq %r13, %rdi
    shlq $1, %rdi
    movq %rdi, %r13
    call tl_alloc
    movq %rax, %r10
    xorq %rbx, %rbx
.L_tl_process_read_copy:
    cmpq %r15, %rbx
    jge .L_tl_process_read_copy_done
    movzbl (%r14,%rbx), %eax
    movb %al, (%r10,%rbx)
    incq %rbx
    jmp .L_tl_process_read_copy
.L_tl_process_read_copy_done:
    movq %r10, %r14
    jmp .L_tl_process_read_loop
.L_tl_process_read_done:
    movq $16, %rdi
    call tl_alloc
    movq %r14, 0(%rax)
    movq %r15, 8(%rax)
    addq $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_make_ok:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    subq $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq $24, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    movq %r13, 16(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    addq $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_make_error:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rdi, %r12
    movq %rsi, %r13
    movq %rdx, %r14
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq %r14, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
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

(define (compiler-backend-runtime-random-system-seed-functions) : String
  "    .globl tl_random_system_seed
tl_random_system_seed:
    push %rbp
    movq %rsp, %rbp
    push %r12
    push %r13
    sub $16, %rsp
    leaq (%rsp), %rdi
    movq $8, %rsi
    xorq %rdx, %rdx
    movq $318, %rax
    syscall
    testq %rax, %rax
    js .L_tl_random_system_seed_err
    cmpq $8, %rax
    jne .L_tl_random_system_seed_err
    movq (%rsp), %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret
.L_tl_random_system_seed_err:
    leaq .L_tl_random_system_seed_err_msg(%rip), %r12
    movq $.L_tl_random_system_seed_err_msg_len, %r13
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-random-system-seed-functions) : String
  "    .globl tl_random_system_seed
tl_random_system_seed:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    sub $16, %rsp
    leaq (%rsp), %rcx
    movl $8, %edx
    sub $32, %rsp
    call SystemFunction036
    add $32, %rsp
    testb %al, %al
    jz .L_tl_random_system_seed_err
    movq (%rsp), %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret
.L_tl_random_system_seed_err:
    leaq .L_tl_random_system_seed_err_msg(%rip), %r12
    movq $.L_tl_random_system_seed_err_msg_len, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-setup-instances-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .globl tl_windows_setup_instances
tl_windows_setup_instances:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    leaq .L_tl_windows_setup_unavailable_msg(%rip), %r12
    movq $.L_tl_windows_setup_unavailable_msg_len, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r13
    pop %r12
    pop %rbp
    ret

"
    "    .globl tl_windows_setup_instances
tl_windows_setup_instances:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    leaq .L_tl_windows_setup_unsupported_msg(%rip), %r12
    movq $.L_tl_windows_setup_unsupported_msg_len, %r13
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r13
    pop %r12
    pop %rbp
    ret

"))

(define (compiler-backend-runtime-functions [plan : CompilerBackendRuntimePlan]) : String
  (compiler-backend-runtime-functions-for-target (BackendTargetLinux) plan))

(define (compiler-backend-runtime-linux-only
  [target : CompilerBackendTarget]
  [enabled : bool]
  [asm : String]) : String
  (if enabled
    (if (compiler-backend-target-windows? target)
      ""
      asm)
    ""))

(define (compiler-backend-runtime-functions-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        string-eq
        string-to-int
        int-to-string
        abort
        print-err
        arg-count
        arg
        read-file
        write-file
        file-exists
        file-read-chunk
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances)
      (let
        [alloc-asm : String
          (if alloc
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-alloc-functions)
              (compiler-backend-runtime-alloc-functions))
            "")]
        [oob-asm : String
          (if oob
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-oob-functions)
              (compiler-backend-runtime-oob-functions))
            "")]
        [substring-asm : String
          (if substring
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-substring-functions)
              (compiler-backend-runtime-substring-functions))
            "")]
        [concat-asm : String
          (if concat
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-concat-functions)
              (compiler-backend-runtime-concat-functions))
            "")]
        [string-eq-asm : String
          (if string-eq
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-string-eq-functions)
              (compiler-backend-runtime-string-eq-functions))
            "")]
        [string-to-int-asm : String
          (if string-to-int
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-string-to-int-functions)
              (compiler-backend-runtime-string-to-int-functions))
            "")]
        [int-to-string-asm : String
          (if int-to-string
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-int-to-string-functions)
              (compiler-backend-runtime-int-to-string-functions))
            "")]
        [abort-asm : String
          (if abort
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-abort-functions)
              (compiler-backend-runtime-abort-functions))
            "")]
        [print-err-asm : String
          (if print-err
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-print-err-functions)
              (compiler-backend-runtime-print-err-functions))
            "")]
        [arg-count-asm : String
          (if arg-count
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-arg-count-functions)
              (compiler-backend-runtime-arg-count-functions))
            "")]
        [arg-asm : String
          (if arg
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-arg-functions)
              (compiler-backend-runtime-arg-functions))
            "")]
        [read-file-asm : String
          (if read-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-file-functions)
              (compiler-backend-runtime-read-file-functions))
            "")]
        [read-file-status-asm : String
          (if read-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-file-status-functions)
              (compiler-backend-runtime-read-file-status-functions))
            "")]
        [write-file-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-write-file-functions)
              (compiler-backend-runtime-write-file-functions))
            "")]
        [write-file-status-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-write-file-status-functions)
              (compiler-backend-runtime-write-file-status-functions))
            "")]
        [append-file-status-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-append-file-status-functions)
              (compiler-backend-runtime-append-file-status-functions))
            "")]
        [file-exists-asm : String
          (if file-exists
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-file-exists-functions)
              (compiler-backend-runtime-file-exists-functions))
            "")]
        [file-exists-status-asm : String
          (if file-exists
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-file-exists-status-functions)
              (compiler-backend-runtime-file-exists-status-functions))
            "")]
        [file-read-chunk-asm : String
          (if file-read-chunk
            (compiler-backend-runtime-file-read-chunk-functions target)
            "")]
        [process-output-asm : String
          (if process-output
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-process-output-functions)
              (compiler-backend-runtime-process-output-functions))
            "")]
        [read-line-asm : String
          (if read-line
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-stdin-line-functions)
              (compiler-backend-runtime-read-stdin-line-functions))
            "")]
        [read-bytes-asm : String
          (if read-bytes
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-stdin-bytes-functions)
              (compiler-backend-runtime-read-stdin-bytes-functions))
            "")]
        [stdin-eof-asm : String
          (if stdin-eof
            (compiler-backend-runtime-stdin-eof-functions)
            "")]
        [flush-stdout-asm : String
          (if flush-stdout
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-flush-stdout-functions)
              (compiler-backend-runtime-flush-stdout-functions))
            "")]
        [region-mark-asm : String
          (compiler-backend-runtime-linux-only
            target
            region-mark
            (compiler-backend-runtime-region-mark-functions))]
        [region-reset-asm : String
          (compiler-backend-runtime-linux-only
            target
            region-reset
            (compiler-backend-runtime-region-reset-functions))]
        [random-system-seed-asm : String
          (if random-system-seed
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-random-system-seed-functions)
              (compiler-backend-runtime-random-system-seed-functions))
            "")]
        [windows-setup-instances-asm : String
          (if windows-setup-instances
            (compiler-backend-runtime-windows-setup-instances-functions target)
            "")]
        [random-and-windows-asm : String
          (string-append random-system-seed-asm windows-setup-instances-asm)]
        (string-append
          alloc-asm
          (string-append
            region-mark-asm
            (string-append
              region-reset-asm
              (string-append
                oob-asm
                (string-append
                  substring-asm
                  (string-append
                    concat-asm
                    (string-append
                      string-eq-asm
                      (string-append
                        string-to-int-asm
                        (string-append
                          int-to-string-asm
                          (string-append
                            abort-asm
                            (string-append
                              print-err-asm
                              (string-append
                                arg-count-asm
                                (string-append
                                  arg-asm
                                  (string-append
                                    read-file-asm
                                    (string-append
                                      read-file-status-asm
                                      (string-append
                                        write-file-asm
                                        (string-append
                                          write-file-status-asm
                                          (string-append
                                            append-file-status-asm
                                            (string-append
                                              file-exists-asm
                                              (string-append
                                                file-exists-status-asm
                                                (string-append
                                                  file-read-chunk-asm
                                                  (string-append
                                                    process-output-asm
                                                    (string-append
                                                      read-line-asm
                                                      (string-append
                                                        read-bytes-asm
                                                        (string-append
                                                          stdin-eof-asm
                                                          (string-append
                                                            flush-stdout-asm
                                                            random-and-windows-asm)))))))))))))))))))))))))))]))

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

(define (compiler-backend-target-float-arg-reg
  [target : CompilerBackendTarget]
  [idx : i64]) : ResultBackendReg
  (match target
    [(BackendTargetLinux) (compiler-backend-float-arg-reg idx)]
    [(BackendTargetWindows)
      (if (= idx 0)
        (OkBackendReg "%xmm0")
        (if (= idx 1)
          (OkBackendReg "%xmm1")
          (if (= idx 2)
            (OkBackendReg "%xmm2")
            (if (= idx 3)
              (OkBackendReg "%xmm3")
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

(define (compiler-backend-entry [capture-argv : bool] [capture-env : bool]) : String
  (if (or capture-argv capture-env)
    (string-append
      "_start:
    movq (%rsp), %rax
"
      (string-append
        (if capture-argv
          "    movq %rax, .L_tl_argc(%rip)
    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
"
          "")
        (string-append
          (if capture-env
            (string-append
              (if capture-argv
                "    movq (%rsp), %rax\n"
                "")
              "    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
")
            "")
          "    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
")))
    "_start:\n    call main\n    movq %rax, %rdi\n    movq $60, %rax\n    syscall\n"))

(define (compiler-backend-entry-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match target
    [(BackendTargetLinux)
      (match plan
        [(BackendRuntimePlan
            _
            _
            _
            _
            _
            _
            _
            _
            _
            arg-count
            arg
            _
            _
            _
            _
            process-output
            _
            _
            _
            _
            _
            _
            _
            _)
          (compiler-backend-entry (or arg-count arg) process-output)])]
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
        string-eq
        string-to-int
        int-to-string
        abort
        print-err
        arg-count
        arg
        read-file
        write-file
        file-exists
        file-read-chunk
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances)
      (not
        (or
          (backend-or8
            alloc
            oob
            substring
            concat
            string-eq
            string-to-int
            int-to-string
            abort)
          (or
            (backend-or8
              print-err
              arg-count
              arg
              read-file
              write-file
              file-exists
              file-read-chunk
              read-line)
            (or
              process-output
              (or
                read-bytes
                (or
                  stdin-eof
                  (or
                    flush-stdout
                    (backend-or4
                      region-mark
                      region-reset
                      random-system-seed
                      windows-setup-instances))))))))]))

(define (compiler-backend-target-runtime-ok?
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : bool
  (if (compiler-backend-target-windows? target)
    (match plan
      [(BackendRuntimePlan
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          _
          region-mark
          region-reset
          _
          _)
        (not (or region-mark region-reset))])
    true))

(define (compiler-backend-runtime-externs-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and
    (compiler-backend-target-windows? target)
    (not (compiler-backend-runtime-plan-empty? plan)))
    (string-append
      "    .extern malloc
    .extern _write
    .extern exit
    .extern _read
    .extern fflush
    .extern _open
    .extern _lseeki64
    .extern _close
    .extern _access
    .extern _errno
"
      (if (compiler-backend-plan-provides? plan "tl_random_system_seed")
        "    .extern SystemFunction036
"
        ""))
    ""))

;; Emit a full program for `target`. Windows x64 has ABI-correct user function
;; entry/calls and target-specific runtime helpers.
;; Backend entry points come in two flavors (#605): the original
;;
;; program-only variants (kept for existing call sites and smoke tests) supply
;;
;; an empty provenance table, so backend diagnostics fall back to `path:1:1`;
;;
;; the `-with-spans` variants thread the lowering provenance side table so
;;
;; backend errors report the offending function's real source location.
(define (compiler-backend-emit-program-for-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-program-target
    program
    target
    (compiler-source-spans-empty)))

(define (compiler-backend-emit-program [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-linux [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-with-spans
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program (BackendTargetLinux) spans))

(define (compiler-backend-emit-program-with-spans-for-target
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program target spans))

(define (compiler-backend-emit-program-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
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
                  plan
                  spans)
                  [(OkCompilerBackend functions-asm)
                    (let
                      [strings : BackendStringList
                        (compiler-backend-collect-program-strings program)]
                      [floats : BackendStringList
                        (compiler-backend-collect-program-f64s program)]
                      [buf : TextBuf
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
                                            (text-buf-append
                                              (text-buf-empty)
                                              ".data\n")
                                            globals-asm)
                                          (compiler-backend-emit-string-rodata
                                            strings))
                                        (compiler-backend-emit-f64-rodata
                                          floats))
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
                          (compiler-backend-entry-for-target target plan))]
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
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-with-spans program spans)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-emit-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-with-spans-for-target program spans target)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-backend-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      true
      (let
        [i : i64 0]
        [found : bool false]
        [done : bool false]
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

(define (compiler-backend-string-count [text : String] [needle : String]) : i64
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      0
      (let
        [i : i64 0]
        [count : i64 0]
        (begin
          (while (<= (+ i needle-len) text-len)
            (if (compiler-backend-string-prefix-at? text needle i)
              (begin
                (set! count (+ count 1))
                (set! i (+ i needle-len)))
              (set! i (+ i 1))))
          count)))))

(define (compiler-backend-runtime-helper-externs) : CompilerIrExternList
  (IrExternCons
    (IrExtern "tl_alloc" (AstTyI64))
    (IrExternCons
      (IrExtern "tl_oob_abort" (AstTyUnit))
      (IrExternCons
        (IrExtern "tl_substring" (AstTyI64))
        (IrExternCons
          (IrExtern "tl_string_concat" (AstTyI64))
          (IrExternCons
            (IrExtern "tl_string_eq" (AstTyBool))
            (IrExternCons
              (IrExtern "tl_string_to_int" (AstTyI64))
              (IrExternCons
                (IrExtern "tl_int_to_string" (AstTyString))
                (IrExternCons
                  (IrExtern "tl_print_err" (AstTyUnit))
                  (IrExternCons
                    (IrExtern ".L_tl_arg_count" (AstTyI64))
                    (IrExternCons
                      (IrExtern ".L_tl_arg" (AstTyString))
                      (IrExternCons
                        (IrExtern ".L_tl_read_file" (AstTyString))
                        (IrExternCons
                          (IrExtern ".L_tl_write_file" (AstTyUnit))
                          (IrExternCons
                            (IrExtern ".L_tl_file_exists" (AstTyBool))
                            (IrExternCons
                              (IrExtern
                                ".L_tl_file_read_chunk_status"
                                (AstTyI64))
                              (IrExternCons
                                (IrExtern
                                  ".L_tl_file_read_chunk_bytes"
                                  (AstTyString))
                                (IrExternCons
                                  (IrExtern
                                    ".L_tl_file_read_chunk_eof"
                                    (AstTyBool))
                                  (IrExternCons
                                    (IrExtern
                                      "tl_process_output"
                                      (AstTyFunc
                                        (AstTypeCons (AstTyI64) AstTypeNil)
                                        (AstTyI64)))
                                    (IrExternCons
                                      (IrExtern
                                        "tl_random_system_seed"
                                        (AstTyI64))
                                      IrExternNil)))))))))))))))))))

(define (compiler-backend-runtime-helper-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        11
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
                            (IrInstrCall
                              7
                              "tl_random_system_seed"
                              IrValueNil
                              (AstTyI64))
                            (IrInstrCons
                              (IrInstrCall
                                8
                                ".L_tl_file_read_chunk_status"
                                (IrValueCons
                                  (IrValueI64 1)
                                  (IrValueCons (IrValueI64 4) IrValueNil))
                                (AstTyI64))
                              (IrInstrCons
                                (IrInstrCall
                                  9
                                  ".L_tl_file_read_chunk_bytes"
                                  (IrValueCons (IrValueI64 1) IrValueNil)
                                  (AstTyString))
                                (IrInstrCons
                                  (IrInstrCall
                                    10
                                    ".L_tl_file_read_chunk_eof"
                                    (IrValueCons (IrValueI64 1) IrValueNil)
                                    (AstTyBool))
                                  (IrInstrCons
                                    (IrInstrReturn
                                      (IrSomeValue (IrValueI64 42)))
                                    IrInstrNil)))))))))))))
          IrBlockNil))
      IrFunctionNil)
    (compiler-backend-runtime-helper-externs)))

(define (compiler-backend-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-program
    (compiler-backend-runtime-helper-program))
    [(OkCompilerBackend asm)
      (let
        [base-labels : bool
          (and
            (backend-and4
              (compiler-backend-string-contains? asm ".globl tl_alloc\n")
              (compiler-backend-string-contains? asm "tl_alloc:\n")
              (compiler-backend-string-contains? asm ".globl tl_oob_abort\n")
              (compiler-backend-string-contains? asm "tl_oob_abort:\n"))
            (compiler-backend-string-contains? asm "tl_current_arena:\n"))]
        [string-labels : bool
          (backend-and8
            (compiler-backend-string-contains? asm ".globl tl_substring\n")
            (compiler-backend-string-contains? asm "tl_substring:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
            (compiler-backend-string-contains? asm "tl_string_concat:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_eq\n")
            (compiler-backend-string-contains? asm "tl_string_eq:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_to_int\n")
            (compiler-backend-string-contains? asm "tl_string_to_int:\n"))]
        [driver-labels : bool
          (backend-and8
            (compiler-backend-string-contains? asm ".globl tl_int_to_string\n")
            (compiler-backend-string-contains? asm "tl_int_to_string:\n")
            (compiler-backend-string-contains? asm ".globl tl_print_err\n")
            (compiler-backend-string-contains? asm "tl_print_err:\n")
            (compiler-backend-string-contains? asm ".L_tl_arg_count:\n")
            (compiler-backend-string-contains? asm ".L_tl_arg:\n")
            (compiler-backend-string-contains? asm ".L_tl_read_file:\n")
            (compiler-backend-string-contains? asm ".L_tl_write_file:\n"))]
        [file-labels : bool
          (backend-and4
            (compiler-backend-string-contains? asm ".L_tl_file_exists:\n")
            (compiler-backend-string-contains? asm ".L_tl_abort:\n")
            (compiler-backend-string-contains? asm ".L_tl_argc:\n")
            (compiler-backend-string-contains? asm ".L_tl_argv:\n"))]
        [file-read-chunk-labels : bool
          (and
            (backend-and8
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_next:\n")
              (compiler-backend-string-contains? asm ".L_tl_file_handle_fds:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_modes:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_states:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_eofs:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_last_ptrs:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_last_lens:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_handle_last_eofs:\n"))
            (and
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_read_chunk_status:\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  ".L_tl_file_read_chunk_bytes:\n")
                (compiler-backend-string-contains?
                  asm
                  ".L_tl_file_read_chunk_eof:\n"))))]
        [stdio-labels : bool
          (backend-and4
            (compiler-backend-string-contains? asm ".L_tl_read_stdin_line:\n")
            (compiler-backend-string-contains? asm ".L_tl_read_stdin_bytes:\n")
            (compiler-backend-string-contains? asm ".L_tl_stdin_eof:\n")
            (compiler-backend-string-contains? asm ".L_tl_flush_stdout:\n"))]
        [process-labels : bool
          (and
            (backend-and4
              (compiler-backend-string-contains? asm "tl_process_output:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_process_read_all:\n")
              (compiler-backend-string-contains?
                asm
                ".L_tl_process_exec_marker:")
              (compiler-backend-string-contains? asm ".L_tl_envp:\n"))
            (compiler-backend-string-contains? asm "process: spawn failed"))]
        [random-labels : bool
          (and
            (compiler-backend-string-contains? asm "tl_random_system_seed:\n")
            (compiler-backend-string-contains?
              asm
              "random: system entropy unavailable"))]
        [file-read-chunk-no-externs : bool
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_file_read_chunk_status\n"))
            (and
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern .L_tl_file_read_chunk_bytes\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern .L_tl_file_read_chunk_eof\n"))))]
        [no-externs : bool
          (and
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
                  ".extern .L_tl_flush_stdout\n")))
            (and
              (backend-and8
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_string_eq\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_string_to_int\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_int_to_string\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_print_err\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern .L_tl_arg_count\n"))
                (not
                  (compiler-backend-string-contains? asm ".extern .L_tl_arg\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern .L_tl_read_file\n"))
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern .L_tl_write_file\n")))
              (and
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern .L_tl_file_exists\n"))
                (and
                  (not
                    (compiler-backend-string-contains?
                      asm
                      ".extern tl_process_output\n"))
                  (not
                    (compiler-backend-string-contains?
                      asm
                      ".extern tl_random_system_seed\n"))))))]
        (and
          base-labels
          (and
            string-labels
            (and
              driver-labels
              (and
                file-labels
                (and
                  file-read-chunk-labels
                  (and
                    stdio-labels
                    (and
                      process-labels
                      (and
                        no-externs
                        (and
                          file-read-chunk-no-externs
                          (and
                            random-labels
                            (and
                              (compiler-backend-string-contains?
                                asm
                                "    call tl_alloc\n")
                              (compiler-backend-string-contains?
                                asm
                                ".L_tl_stdin_eof_flag:\n")))))))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-driver-runtime-source) : String
  "(define (main) : i64
  (if (< (arg-count) 3)
    (begin
      (print-error \"runtime driver: expected input and output paths\")
      2)
    (let ([input : String (arg 1)]
          [output : String (arg 2)])
      (let ([content : String (read-file input)])
        (if (file-exists? input)
          (let ([n : i64 (string->int content)])
            (let ([rendered : String (int->string (+ n 1))])
              (begin
                (if (string-eq content \"41\")
                  (print-error \"ok\")
                  (print-error \"mismatch\"))
                (write-file output rendered)
                42)))
          3)))))")

(define (compiler-backend-windows-driver-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-windows-driver-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".L_tl_arg_count:\n")
          (compiler-backend-string-contains? asm ".L_tl_arg:\n")
          (compiler-backend-string-contains? asm ".L_tl_read_file:\n")
          (compiler-backend-string-contains? asm ".L_tl_write_file:\n")
          (compiler-backend-string-contains? asm ".L_tl_file_exists:\n")
          (compiler-backend-string-contains? asm "tl_print_err:\n")
          (compiler-backend-string-contains? asm "tl_string_eq:\n")
          (compiler-backend-string-contains? asm "tl_string_to_int:\n"))
        (and
          (compiler-backend-string-contains? asm "tl_int_to_string:\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movq %rcx, .L_tl_argc(%rip)\n")
            (and
              (compiler-backend-string-contains? asm "    call _open\n")
              (and
                (compiler-backend-string-contains? asm "    call _lseeki64\n")
                (and
                  (compiler-backend-string-contains? asm "    call _close\n")
                  (and
                    (compiler-backend-string-contains? asm "    call _access\n")
                    (not (compiler-backend-string-contains? asm "syscall\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-alloc-runtime-arena-ok?) : bool
  (match (compiler-backend-emit-program
    (compiler-backend-runtime-helper-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_current_arena:\n")
        (and
          (compiler-backend-string-contains?
            asm
            "    movq tl_current_arena(%rip), %r8\n")
          (and
            (compiler-backend-string-contains? asm ".L_tl_alloc_new_arena:\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movq $0x4000000, %rdx\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movq %rax, tl_current_arena(%rip)\n")
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".L_tl_alloc_size_ready:\n")))))))]
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

(define (compiler-backend-module-symbol-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "lib.tl::helper"
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
                (IrInstrCall 0 "lib.tl::helper" IrValueNil (AstTyI64))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-module-symbol-ok?) : bool
  (match (compiler-backend-emit-program
    (compiler-backend-module-symbol-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          ".globl _tl_lib_u2etl_colon_colonhelper\n")
        (and
          (compiler-backend-string-contains?
            asm
            "_tl_lib_u2etl_colon_colonhelper:\n")
          (compiler-backend-string-contains?
            asm
            "    call _tl_lib_u2etl_colon_colonhelper\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-smoke-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if (> x 44) x 0))))")

;; SysV call with more than six integer args (#750): args 7+ spill to the
;; stack. `add8` reads its last two (stack-passed) params, exercising both the
;; outgoing stack stores at the call and the incoming stack reads in the callee.
(define (compiler-backend-stack-int-args-source) : String
  "(define (add8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ g h))
(define (main) : i64
  (add8 1 2 3 4 5 6 7 8))")

;; SysV call with more than eight f64 args (#750): xmm0..xmm7 then stack.
(define (compiler-backend-stack-f64-args-source) : String
  "(define (sum10
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : f64
  (+ i j))
(define (main) : i64
  (if (< (sum10 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0) 20.0) 1 0))")

;; Mixed int/f64 call that exhausts both banks and spills (#750): the integer
;; and float register indexes advance independently under System V. There are 7
;; integer args (rdi..r9 then one stacked) and 9 f64 args (xmm0..xmm7 then one
;; stacked); `mix` returns the sum of the two stack-passed args.
(define (compiler-backend-stack-mixed-args-source) : String
  "(define (mix
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (+ i6 (if (< f8 100.0) 1 0)))
(define (main) : i64
  (mix 1 2 3 4 5 6 7 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))")

;; #750 RUN-LEVEL witness source: a self-contained program that exercises all
;; three spill paths (integer, f64, and mixed) and returns 96 only when every
;; stack-passed argument arrives with the correct value and ordering. Emitted by
;; the stack-args fixture, then assembled, linked, and run by the integration
;; suite. `add8` returns g*10+h (78) so a swapped/wrong-offset int stack arg
;; changes the result; `f10check` checks the two spilled xmm-overflow floats
;; (1); `mixcheck` keeps the integer and float banks independent and returns the
;; spilled integer (17) only when the spilled float carries its value. 78+1+17.
(define (compiler-backend-stack-args-fixture-source) : String
  "(define (add8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ (* g 10) h))
(define (f10check
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : i64
  (if
    (and (and (< 8.5 i) (< i 9.5)) (and (< 9.5 j) (< j 10.5)))
    1
    0))
(define (mixcheck
  [i0 : i64]
  [i1 : i64]
  [i2 : i64]
  [i3 : i64]
  [i4 : i64]
  [i5 : i64]
  [i6 : i64]
  [f0 : f64]
  [f1 : f64]
  [f2 : f64]
  [f3 : f64]
  [f4 : f64]
  [f5 : f64]
  [f6 : f64]
  [f7 : f64]
  [f8 : f64]) : i64
  (if (and (< 8.5 f8) (< f8 9.5)) i6 0))
(define (main) : i64
  (+
    (add8 1 2 3 4 5 6 7 8)
    (+
      (f10check 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)
      (mixcheck 11 12 13 14 15 16 17 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))))")

(define (compiler-backend-stack-args-fixture-emit
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-source-for-target
    (compiler-backend-stack-args-fixture-source)
    target))

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
  (let
    [x : i64 (+ a b)]
    [y : i64 (* x 2)]
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
                          "    testq %rax, %rax\n")
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

;; Backend-owned replacement for the string runtime helper emission tests
;; (#1044): source-level string builtins lower to direct calls, and the backend
;; emits each helper body instead of leaving an extern placeholder.
(define (compiler-backend-string-runtime-source) : String
  "(define (parse-and-render [s : String]) : i64
  (+
    (string->int s)
    (+
      (string-length (int->string 42))
      (+
        (string-length (substring s 0 1))
        (string-length (string-concat s \"!\"))))))
(define (main) : i64 (parse-and-render \"42\"))")

(define (compiler-backend-string-runtime-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-string-runtime-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_string_to_int\n")
          (compiler-backend-string-contains? asm "tl_string_to_int:\n")
          (compiler-backend-string-contains? asm "    call tl_string_to_int\n")
          (compiler-backend-string-contains? asm ".globl tl_int_to_string\n")
          (compiler-backend-string-contains? asm "tl_int_to_string:\n")
          (compiler-backend-string-contains? asm "    call tl_int_to_string\n")
          (compiler-backend-string-contains? asm ".globl tl_substring\n")
          (compiler-backend-string-contains? asm "    call tl_substring\n"))
        (and
          (backend-and8
            (compiler-backend-string-contains? asm "tl_substring:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
            (compiler-backend-string-contains? asm "tl_string_concat:\n")
            (compiler-backend-string-contains?
              asm
              "    call tl_string_concat\n")
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_string_to_int\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_int_to_string\n"))
            (not
              (compiler-backend-string-contains? asm ".extern tl_substring\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_string_concat\n")))
          (not
            (compiler-backend-string-contains?
              asm
              (compiler-backend-todo-marker)))))]
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

(define (compiler-backend-peephole-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (CompilerRegAssignmentCons
      (CompilerRegAssignment 1 (CompilerRegRegister "%xmm0"))
      (CompilerRegAssignmentCons
        (CompilerRegAssignment 2 (CompilerRegRegister "%r13"))
        CompilerRegAssignmentNil))))

(define (compiler-backend-expanded-scalar-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r8"))
    (CompilerRegAssignmentCons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r9"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-expanded-scalar-regs-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-expanded-scalar-assignments)]
    (and
      (string-eq
        (compiler-backend-emit-load-var-with-plan assignments 0 "%rax")
        "    movq %r8, %rax\n")
      (and
        (string-eq
          (compiler-backend-emit-store-var-with-plan assignments 1 "%rax")
          "    movq %rax, %r9\n")
        (and
          (string-eq
            (compiler-backend-emit-load-register "%r8" (AstTyU32))
            "    movl %r8d, %eax\n")
          (and
            (not (compiler-backend-plan-uses-callee-regs? assignments))
            (= (compiler-backend-frame-slots 2 assignments) 2)))))))

(define (compiler-backend-peephole-register-moves-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    (and
      (string-eq
        (compiler-backend-emit-load-var-with-plan assignments 0 "%r12")
        "")
      (and
        (string-eq
          (compiler-backend-emit-store-var-with-plan assignments 0 "%r12")
          "")
        (and
          (string-eq
            (compiler-backend-emit-load-f64-var-with-plan assignments 1 "%xmm0")
            "")
          (string-eq
            (compiler-backend-emit-store-f64-var-with-plan
              assignments
              1
              "%xmm0")
            ""))))))

(define (compiler-backend-peephole-asm-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-backend-peephole-assignments)]
    (match (compiler-backend-emit-binop
      (CompilerRegVarTypeNil)
      assignments
      2
      (IrBinAdd)
      (IrValueVar 0)
      (IrValueI64 5)
      (AstTyI64))
      [(OkCompilerBackend add-asm)
        (match (compiler-backend-emit-binop
          (CompilerRegVarTypeNil)
          assignments
          2
          (IrBinLt)
          (IrValueVar 0)
          (IrValueI64 10)
          (AstTyI64))
          [(OkCompilerBackend cmp-asm)
            (match (compiler-backend-emit-branch
              assignments
              "peephole"
              (IrValueVar 0)
              "then"
              "else")
              [(OkCompilerBackend branch-asm)
                (and
                  (compiler-backend-string-contains?
                    add-asm
                    "    addq $5, %rax\n")
                  (and
                    (not
                      (compiler-backend-string-contains?
                        add-asm
                        "    movq $5, %rbx\n"))
                    (and
                      (compiler-backend-string-contains?
                        cmp-asm
                        "    cmpq $10, %rax\n    setl %al\n")
                      (and
                        (compiler-backend-string-contains?
                          branch-asm
                          "    testq %rax, %rax\n    jne ")
                        (not
                          (compiler-backend-string-contains?
                            branch-asm
                            "    cmpq $0, %rax\n    jne "))))))]
              [(ErrCompilerBackend _) false])]
          [(ErrCompilerBackend _) false])]
      [(ErrCompilerBackend _) false])))

(define (compiler-backend-peephole-ok?) : bool
  (and
    (compiler-backend-peephole-register-moves-ok?)
    (compiler-backend-peephole-asm-ok?)))

(define (compiler-backend-phi-same-home-assignments) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons
    (CompilerRegAssignment 0 (CompilerRegRegister "%r12"))
    (CompilerRegAssignmentCons
      (CompilerRegAssignment 1 (CompilerRegRegister "%r12"))
      CompilerRegAssignmentNil)))

(define (compiler-backend-phi-same-home-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "join"
      (IrInstrCons
        (IrInstrPhi
          1
          (IrPhiInputCons (IrPhiInput (IrValueVar 0) "entry") IrPhiInputNil)
          (AstTyI64))
        IrInstrNil))
    IrBlockNil))

(define (compiler-backend-phi-cycle-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "join"
      (IrInstrCons
        (IrInstrPhi
          0
          (IrPhiInputCons (IrPhiInput (IrValueVar 1) "back") IrPhiInputNil)
          (AstTyI64))
        (IrInstrCons
          (IrInstrPhi
            1
            (IrPhiInputCons (IrPhiInput (IrValueVar 0) "back") IrPhiInputNil)
            (AstTyI64))
          IrInstrNil)))
    IrBlockNil))

(define (compiler-backend-phi-parallel-copy-ok?) : bool
  (match (compiler-backend-emit-phi-edge-copies
    (compiler-backend-phi-same-home-assignments)
    (compiler-backend-phi-same-home-blocks)
    "join"
    "entry")
    [(OkCompilerBackend same-home)
      (match (compiler-backend-emit-phi-edge-copies
        CompilerRegAssignmentNil
        (compiler-backend-phi-cycle-blocks)
        "join"
        "back")
        [(OkCompilerBackend cycle)
          (and
            (string-eq same-home "")
            (and
              (compiler-backend-string-contains?
                cycle
                "    movq -8(%rbp), %r11\n")
              (and
                (compiler-backend-string-contains?
                  cycle
                  "    movq -16(%rbp), %rax\n")
                (and
                  (compiler-backend-string-contains?
                    cycle
                    "    movq %rax, -8(%rbp)\n")
                  (compiler-backend-string-contains?
                    cycle
                    "    movq %r11, -16(%rbp)\n")))))]
        [(ErrCompilerBackend _) false])]
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
                            "    movq %r11, 32(%rsp)\n")
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
                  (compiler-backend-string-contains? asm "    call _open\n")
                  (and
                    (compiler-backend-string-contains?
                      asm
                      "    call _lseeki64\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    call _access\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "tl_substring:\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "tl_string_concat:\n")
                          (and
                            (compiler-backend-string-contains?
                              asm
                              "tl_string_eq:\n")
                            (and
                              (compiler-backend-string-contains?
                                asm
                                "tl_string_to_int:\n")
                              (and
                                (compiler-backend-string-contains?
                                  asm
                                  "tl_int_to_string:\n")
                                (and
                                  (compiler-backend-string-contains?
                                    asm
                                    ".L_tl_arg:\n")
                                  (and
                                    (compiler-backend-string-contains?
                                      asm
                                      ".L_tl_read_file:\n")
                                    (and
                                      (compiler-backend-string-contains?
                                        asm
                                        ".L_tl_write_file:\n")
                                      (and
                                        (compiler-backend-string-contains?
                                          asm
                                          ".L_tl_file_exists:\n")
                                        (and
                                          (compiler-backend-string-contains?
                                            asm
                                            ".L_tl_file_read_chunk_status:\n")
                                          (and
                                            (compiler-backend-string-contains?
                                              asm
                                              ".L_tl_file_read_chunk_bytes:\n")
                                            (and
                                              (compiler-backend-string-contains?
                                                asm
                                                ".L_tl_file_read_chunk_eof:\n")
                                              (and
                                                (not
                                                  (compiler-backend-string-contains?
                                                    asm
                                                    ".L_tl_file_handle_next:\n"))
                                                (and
                                                  (compiler-backend-string-contains?
                                                    asm
                                                    "    movq %rcx, .L_tl_argc(%rip)\n")
                                                  (and
                                                    (compiler-backend-string-contains?
                                                      asm
                                                      "    .extern malloc\n")
                                                    (and
                                                      (not
                                                        (compiler-backend-string-contains?
                                                          asm
                                                          "syscall\n"))
                                                      (compiler-backend-windows-driver-runtime-ok?)))))))))))))))))))))))))]
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

(define (compiler-backend-source-contains? [src : String] [needle : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm) (compiler-backend-string-contains? asm needle)]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-source-not-contains? [src : String] [needle : String]) : bool
  (match (compiler-backend-emit-source src)
    [(OkCompilerBackend asm)
      (not (compiler-backend-string-contains? asm needle))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-test-span [line : i64] [col : i64]) : AstSourceSpan
  (AstSourceSpan line col line col))

(define (compiler-backend-instr-diagnostic-case-ok?
  [instr : CompilerIrInstr]
  [want-message : String]
  [want-line : i64]
  [want-col : i64]) : bool
  (let
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert
          (compiler-source-spans-empty)
          "main"
          (compiler-backend-test-span 10 2))
        "main"
        instr
        (compiler-backend-test-span want-line want-col))]
    [program : CompilerIrProgram
      (IrProgram
        IrGlobalNil
        (IrFunctionCons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (IrBlockCons
              (IrBlock "entry" (IrInstrCons instr IrInstrNil))
              IrBlockNil))
          IrFunctionNil)
        IrExternNil)]
    (match (compiler-backend-emit-program-with-spans program spans)
      [(ErrCompilerBackend diag)
        (and
          (string-eq (compiler-diagnostic-message diag) want-message)
          (and
            (= (compiler-diagnostic-line diag) want-line)
            (= (compiler-diagnostic-col diag) want-col)))]
      [(OkCompilerBackend _) false])))

(define (compiler-backend-instr-diagnostics-ok?) : bool
  (and
    (compiler-backend-instr-diagnostic-case-ok?
      (IrInstrMov 0 (IrValueF64 "1.0") (AstTyI64))
      "backend: f64 values are not supported yet"
      21
      7)
    (and
      (compiler-backend-instr-diagnostic-case-ok?
        (IrInstrBinOp
          1
          (IrBinMod)
          (IrValueF64 "1.0")
          (IrValueF64 "2.0")
          (AstTyF64))
        "backend: unsupported f64 binary op"
        34
        9)
      ;; #1044: an f64 unary op other than negation is rejected (mirrors the
      ;; f64-binary-op reject; only IrUnNeg has an f64 lowering).
      (and
        (compiler-backend-instr-diagnostic-case-ok?
          (IrInstrUnOp 2 (IrUnNot) (IrValueF64 "1.0") (AstTyF64))
          "backend: unsupported f64 unary op"
          40
          11)
        (compiler-backend-instr-diagnostic-case-ok?
          (IrInstrLaneId 3 4 (AstTyI64))
          "backend: vector/mask IR emission is not implemented"
          44
          13)))))

(define (compiler-backend-optimizer-rewrite-diagnostic-ok?) : bool
  (let
    [phi : CompilerIrInstr
      (IrInstrPhi
        0
        (IrPhiInputCons (IrPhiInput (IrValueF64 "1.0") "entry") IrPhiInputNil)
        (AstTyI64))]
    [program : CompilerIrProgram
      (IrProgram
        IrGlobalNil
        (IrFunctionCons
          (IrFunction
            "main"
            IrParamNil
            (AstTyI64)
            4
            (IrBlockCons
              (IrBlock "entry" (IrInstrCons (IrInstrJump "join") IrInstrNil))
              (IrBlockCons
                (IrBlock
                  "join"
                  (IrInstrCons
                    phi
                    (IrInstrCons
                      (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                      IrInstrNil)))
                IrBlockNil)))
          IrFunctionNil)
        IrExternNil)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert
          (compiler-source-spans-empty)
          "main"
          (compiler-backend-test-span 10 2))
        "main"
        phi
        (compiler-backend-test-span 55 13))]
    (match (optimize-program-with-spans program spans)
      [(CompilerOptimizedProgram optimized optimized-spans)
        (match (compiler-backend-emit-program-with-spans
          optimized
          optimized-spans)
          [(ErrCompilerBackend diag)
            (and
              (string-eq
                (compiler-diagnostic-message diag)
                "backend: f64 values are not supported yet")
              (and
                (= (compiler-diagnostic-line diag) 55)
                (= (compiler-diagnostic-col diag) 13)))]
          [(OkCompilerBackend _) false])])))

(define (compiler-backend-instr-contains?
  [instr : CompilerIrInstr]
  [needle : String]) : bool
  (match (compiler-backend-emit-instr
    (BackendTargetLinux)
    "_tl_test"
    "test"
    IrBlockNil
    "entry"
    instr
    CompilerRegAssignmentNil
    8
    CompilerRegVarTypeNil
    (AstTyI64)
    (BackendRuntimePlan
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false
      false)
    IrFunctionNil
    IrExternNil
    (compiler-source-spans-empty)
    (compiler-diagnostic-at-start "" ""))
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
          (and
            (compiler-backend-instr-contains?
              (IrInstrCast 6 (IrValueVar 5) (AstTyI8) (AstTyI64))
              "    movsbq -48(%rbp), %rax\n")
            (compiler-backend-instr-contains?
              (IrInstrBoundsCheck (IrValueVar 1) (IrValueVar 2) "bounds_ok")
              "    jb .L_tl_test_bounds_ok\n")))))))

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
  (let
    [a : (Array i64) (make-array i64 2)]
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

(define (compiler-backend-region-source) : String
  "(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))")

(define (compiler-backend-region-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-region-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    call tl_region_mark\n")
        (and
          (compiler-backend-string-contains? asm "    call tl_region_reset\n")
          (and
            (compiler-backend-string-contains? asm "tl_region_mark:\n")
            (and
              (compiler-backend-string-contains? asm "tl_region_reset:\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  ".L_tl_region_reset_msg:")
                (and
                  (not
                    (compiler-backend-string-contains?
                      asm
                      ".extern tl_region_mark\n"))
                  (not
                    (compiler-backend-string-contains?
                      asm
                      ".extern tl_region_reset\n"))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-process-output-source) : String
  "(extern tl_process_output : (-> i64 i64))
(define (main) : i64 (tl_process_output 0))")

(define (compiler-backend-process-output-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-process-output-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_process_output:\n")
        (and
          (compiler-backend-string-contains? asm "    call tl_process_output\n")
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_process_output\n"))
            (and
              (not
                (compiler-backend-string-contains? asm "_tl_tl_process_output"))
              (and
                (compiler-backend-string-contains?
                  asm
                  ".L_tl_process_read_all:\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    ".L_tl_process_exec_marker:")
                  (and
                    (compiler-backend-string-contains? asm ".L_tl_envp:\n")
                    (and
                      (compiler-backend-string-contains?
                        asm
                        "    movq $57, %rax\n")
                      (and
                        (compiler-backend-string-contains?
                          asm
                          "    movq $59, %rax\n")
                        (and
                          (compiler-backend-string-contains?
                            asm
                            "    movq $61, %rax\n")
                          (and
                            (compiler-backend-string-contains?
                              asm
                              "    movq $319, %rax\n")
                            (and
                              (compiler-backend-string-contains?
                                asm
                                "    movq $293, %rax\n")
                              (compiler-backend-string-contains?
                                asm
                                "tl_alloc:\n")))))))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-process-output-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-process-output-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_process_output:\n")
        (and
          (compiler-backend-string-contains?
            asm
            "process: runtime execution is not supported on this target")
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".extern tl_process_output\n"))
            (and
              (not
                (compiler-backend-string-contains? asm "_tl_tl_process_output"))
              (and
                (not (compiler-backend-string-contains? asm "    syscall"))
                (and
                  (not (compiler-backend-string-contains? asm ".L_tl_envp:\n"))
                  (compiler-backend-string-contains? asm "tl_alloc:\n")))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-append-file-status-ok?) : bool
  (match (compiler-backend-emit-source
    "(define (main) : i64 (append-file-status \"out.txt\" \"x\"))")
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".L_tl_append_file_status:\n")
        (and
          (compiler-backend-string-contains? asm "    movq $1089, %rdx\n")
          (not
            (compiler-backend-string-contains?
              asm
              ".extern .L_tl_append_file_status\n"))))]
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

(define (compiler-backend-f64-source) : String
  "(define (addf [a : f64] [b : f64]) : f64
  (+ a b))
(define (subf [a : f64] [b : f64]) : f64
  (- a b))
(define (ltf [a : f64] [b : f64]) : bool
  (< a b))
(define (main) : i64
  (if (ltf (subf (addf 1.5 2.5) 1.0) 4.5) 7 9))")

(define (compiler-backend-f64-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-f64-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "    .double 1.5\n")
        (and
          (compiler-backend-string-contains? asm "    movsd %xmm0, ")
          (and
            (compiler-backend-string-contains? asm "    movsd %xmm1, ")
            (and
              (compiler-backend-string-contains? asm "    addsd %xmm1, %xmm0\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    subsd %xmm1, %xmm0\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    ucomisd %xmm1, %xmm0\n")
                  (compiler-backend-string-contains? asm "    setb %al\n")))))))]
    [(ErrCompilerBackend _) false]))

;; Backend-owned replacement for the Rust bool logic codegen checks (#1044):
;; `and`/`or` arrive from the lowerer as branches, not eager bytewise ops, and
;; bool equality still uses the comparison/setcc path.
(define (compiler-backend-bool-and-source) : String
  "(define (f [a : bool] [b : bool]) : bool (and a b))")

(define (compiler-backend-bool-or-source) : String
  "(define (f [a : bool] [b : bool]) : bool (or a b))")

(define (compiler-backend-bool-eq-source) : String
  "(define (f [a : bool] [b : bool]) : bool (= a b))")

(define (compiler-backend-todo-marker) : String
  (string-append "# " "TODO"))

(define (compiler-backend-bool-control-flow-ok?) : bool
  (backend-and8
    (compiler-backend-source-contains?
      (compiler-backend-bool-and-source)
      "    jne ")
    (compiler-backend-source-not-contains?
      (compiler-backend-bool-and-source)
      "    andb ")
    (compiler-backend-source-contains?
      (compiler-backend-bool-or-source)
      "    jne ")
    (compiler-backend-source-not-contains?
      (compiler-backend-bool-or-source)
      "    orb ")
    (compiler-backend-source-contains?
      (compiler-backend-bool-eq-source)
      "    sete %al\n")
    (compiler-backend-source-not-contains?
      (compiler-backend-bool-and-source)
      (compiler-backend-todo-marker))
    (compiler-backend-source-not-contains?
      (compiler-backend-bool-or-source)
      (compiler-backend-todo-marker))
    (compiler-backend-source-not-contains?
      (compiler-backend-bool-eq-source)
      (compiler-backend-todo-marker))))

;; #750: a SysV call with seven integer args no longer rejects as "too many
;; call args". The 7th arg spills: 16-byte call space is reserved, the spilled
;; value is staged through %r11 and stored at 0(%rsp), and `add8` reads its
;; stack-passed params back from 16(%rbp)/24(%rbp).
(define (compiler-backend-stack-int-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-int-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
          (and
            (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
            (and
              (compiler-backend-string-contains? asm "    addq $16, %rsp\n")
              (and
                (compiler-backend-string-contains? asm "    call _tl_add8\n")
                (and
                  (compiler-backend-string-contains?
                    asm
                    "    movq 16(%rbp), %rax\n")
                  (compiler-backend-string-contains?
                    asm
                    "    movq 24(%rbp), %rax\n")))))))]
    [(ErrCompilerBackend _) false]))

;; #750: a SysV call with ten f64 args uses xmm0..xmm7 then spills two on the
;; stack through %xmm15; the callee reads them back via movsd from the incoming
;; stack slots.
(define (compiler-backend-stack-f64-args-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-stack-f64-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    subq $16, %rsp\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movsd %xmm15, 0(%rsp)\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movsd %xmm15, 8(%rsp)\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movsd 16(%rbp), %xmm0\n")
                (compiler-backend-string-contains?
                  asm
                  "    movsd 24(%rbp), %xmm0\n"))))))]
    [(ErrCompilerBackend _) false]))

;; #750: a mixed call spilling one int and one f64 keeps the integer and float
;; register banks independent and uses the right scratch register for each
;; spilled arg.
(define (compiler-backend-stack-mixed-args-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-stack-mixed-args-source))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    movq %r11, 0(%rsp)\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movsd %xmm15, 8(%rsp)\n")
            (compiler-backend-string-contains? asm "    call _tl_mix\n"))))]
    [(ErrCompilerBackend _) false]))

;; #750: the Windows positional ABI still reserves 32-byte shadow space, stacks
;; args after the first four, and stores them after the shadow space.
(define (compiler-backend-stack-windows-args-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-stack-int-args-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (not (compiler-backend-string-contains? asm "too many call args"))
        (and
          (compiler-backend-string-contains? asm "    subq $64, %rsp\n")
          (and
            (compiler-backend-string-contains? asm "    movq %r11, 32(%rsp)\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movq %r11, 56(%rsp)\n")
              (compiler-backend-string-contains?
                asm
                "    movq 48(%rbp), %rax\n")))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-stack-args-ok?) : bool
  (and
    (compiler-backend-stack-int-args-ok?)
    (and
      (compiler-backend-stack-f64-args-ok?)
      (and
        (compiler-backend-stack-mixed-args-ok?)
        (compiler-backend-stack-windows-args-ok?)))))

(define (compiler-backend-self-test) : i64
  (if (and
    (backend-and8
      (compiler-backend-target-model-ok? (compiler-backend-smoke-source))
      (compiler-backend-array-access-asm-ok?)
      (compiler-backend-make-array-ok?)
      (compiler-backend-source-ok? (compiler-backend-smoke-source))
      (compiler-backend-deterministic-ok? (compiler-backend-smoke-source))
      (compiler-backend-string-ok?)
      (compiler-backend-memory-op-ok?)
      (compiler-backend-aggregate-ok?))
    (and
      (backend-and8
        (compiler-backend-literal-payload-ok?)
        (compiler-backend-enum-match-ok?)
        (compiler-backend-regalloc-ok?)
        (compiler-backend-peephole-ok?)
        (compiler-backend-phi-parallel-copy-ok?)
        (compiler-backend-f64-ok?)
        (compiler-backend-bool-control-flow-ok?)
        (compiler-backend-stack-args-ok?))
      (and
        (backend-and8
          (compiler-backend-instr-diagnostics-ok?)
          (compiler-backend-optimizer-rewrite-diagnostic-ok?)
          (compiler-backend-runtime-helper-asm-ok?)
          (compiler-backend-alloc-runtime-arena-ok?)
          (compiler-backend-region-ok?)
          (compiler-backend-process-output-ok?)
          (compiler-backend-windows-process-output-ok?)
          (compiler-backend-append-file-status-ok?))
        (and
          (compiler-backend-user-helper-name-ok?)
          (and
            (compiler-backend-string-runtime-ok?)
            (and
              (compiler-backend-expanded-scalar-regs-ok?)
              (and
                (compiler-backend-runtime-coexist-ok?)
                (compiler-backend-module-symbol-ok?))))))))
    42
    (begin
      (panic "backend: smoke output mismatch")
      0)))