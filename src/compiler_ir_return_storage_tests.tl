;; Authored IR controls for signature/range admission. Expected decisions are
;; stated independently of the production proof; no rendered-output oracle.
(import compiler_ir_return_storage as storage)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.iterator)

(define (internal-callee) : ir.CompilerIrFunction
  (irt.func
    "function @make(output=%0:u64) -> u64 vars 1 abi return-storage internal-trailing arg 0 bytes 24 output SretValue result u64 params (u64) source (-> SretValue) {
     entry:
       return %0
     }"))

(define (lifetime-callee) : ir.CompilerIrFunction
  (irt.func
    "function @make(output=%0:u64) -> (SretValue declared) vars 1 abi return-storage internal-trailing arg 0 bytes 24 output (SretValue declared) result (SretValue declared) params (u64) source (-> (SretValue declared)) {\nentry:\nreturn %0\n}"))

(define (foreign-callee) : ir.CompilerIrExtern
  (match (irt.func
    "function @make(output=%0:u64) -> u64 vars 1 abi return-storage sysv arg 0 bytes 24 output SretValue result u64 params (u64) source (-> SretValue) {
     entry:
       return %0
     }")
    [(ir.CompilerIrFunction.Function name _ _ _ _ abi)
      (match abi
        [(ir.CompilerIrFunctionAbi.ReturnStorage boxed)
          (let
            [contract : ir.CompilerIrReturnStorageAbi
              (ir.compiler-ir-box-shared-view boxed)]
            (ir.CompilerIrExtern.Extern
              name
              name
              "make"
              contract.source-signature
              (ast.AstExternAbi.C)
              name
              (ast.ast-extern-link-input-list-new)
              false
              (ir.CompilerIrReturnStorage.Some boxed)))]
        [_
          (ir.CompilerIrExtern.Extern
            name
            name
            "invalid"
            (ast.AstType.Unit)
            (ast.AstExternAbi.C)
            name
            (ast.ast-extern-link-input-list-new)
            false
            (ir.CompilerIrReturnStorage.None))])]))

(define (caller [params : String] [body : String]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @caller("
      params
      ") -> unit vars 12 {\nentry:\n"
      body
      "\nreturn\n}")))

(define (foreign-value-callee [nullable? : bool]) : ir.CompilerIrExtern
  (match (foreign-callee)
    [(ir.CompilerIrExtern.Extern
        name
        source
        symbol
        signature
        abi
        symbol-id
        links
        provided
        storage)
      (ir.CompilerIrExtern.Extern
        name
        source
        symbol
        (ast.AstType.CFunc
          (ast.ast-node-pool-context-type-push
            (ast.ast-node-pool-reader-context-current)
            signature)
          (if nullable?
            (ast.AstCFunctionMode.Nullable)
            (ast.AstCFunctionMode.NonNull)))
        abi
        symbol-id
        links
        provided
        storage)]))

(define (private-body [tail : String]) : String
  (str_cat.str-cat
    "%0 = alloc SretValue\n%1 = alloc SretValue\n%2 = alloc SretValue\n%3 = addr_of %2 storage 3\n"
    tail))

;; declaration: 0=unavailable, 1=internal, 2=C, 3=known ordinary function.
(define (catalog [declaration : i64]) : ir.CompilerIrReturnStorageIndex
  (let
    [functions : ir.CompilerIrFunctionSeq
      (cond
        [(= declaration 1) (ir.compiler-ir-function-seq1 (& (internal-callee)))]
        [(= declaration 8) (ir.compiler-ir-function-seq1 (& (lifetime-callee)))]
        [(= declaration 3)
          (ir.compiler-ir-function-seq1
            (&
              (irt.func
                "function @make(value=%0:u64) -> u64 vars 1 {
             entry:
               return %0
             }")))]
        [else (ir.compiler-ir-function-seq-empty)])]
    [externs : ir.CompilerIrExternSeq
      (cond
        [(= declaration 2) (ir.compiler-ir-extern-seq1 (foreign-callee))]
        ;; One symbol declared both as a function and as a CFunc data value:
        ;; conflicting evidence invalidates the whole catalog.
        [(= declaration 4)
          (ir.compiler-ir-extern-seq2
            (foreign-callee)
            (foreign-value-callee false))]
        ;; Two modules declaring the identical foreign function denote one
        ;; entity, exactly as a single declaration does.
        [(= declaration 7)
          (ir.compiler-ir-extern-seq2 (foreign-callee) (foreign-callee))]
        [(and (>= declaration 5) (<= declaration 6))
          (ir.compiler-ir-extern-seq1 (foreign-value-callee (= declaration 6)))]
        [else (ir.compiler-ir-extern-seq-empty)])]
    [canonical-functions : ir.CompilerIrFunctionSeq
      (cond
        [(= declaration 1) (ir.compiler-ir-function-seq1 (& (internal-callee)))]
        [(= declaration 8) (ir.compiler-ir-function-seq1 (& (lifetime-callee)))]
        [else (ir.compiler-ir-function-seq-empty)])]
    [canonical-externs : ir.CompilerIrExternSeq
      (cond
        [(= declaration 2) (ir.compiler-ir-extern-seq1 (foreign-callee))]
        [(= declaration 7)
          (ir.compiler-ir-extern-seq2 (foreign-callee) (foreign-callee))]
        [(and (>= declaration 5) (<= declaration 6))
          (ir.compiler-ir-extern-seq1 (foreign-value-callee (= declaration 6)))]
        [else (ir.compiler-ir-extern-seq-empty)])]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [canonical : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-claims
        (ast.ast-node-pool-context-type-segment-bases pools)
        (ir.compiler-ir-type-pool-count pools)
        canonical-functions
        canonical-externs)]
    [authority : ir.CompilerIrReturnStorageAuthority
      (ir.compiler-ir-return-storage-authority-capture
        pools
        interns
        0
        canonical)]
    (ir.compiler-ir-return-storage-index-authorized
      pools
      interns
      0
      functions
      externs
      authority)))

(define (proof-code [proof : storage.ReturnStorageProof]) : i64
  (match proof
    [(storage.ReturnStorageProof.Known _) 1]
    [(storage.ReturnStorageProof.Unavailable) 0]
    [(storage.ReturnStorageProof.Invalid _) -1]))

(define (case?
  [declaration : i64]
  [params : String]
  [body : String]
  [expected : i64]) : bool
  (let
    [source : ir.CompilerIrFunction (caller params body)]
    [context : ir.CompilerIrReturnStorageIndex (catalog declaration)]
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    (match source
      [(ir.CompilerIrFunction.Function _ params _ vars blocks abi)
        (let
          [facts : storage.StorageFacts
            (storage.facts bases params abi blocks vars)]
          [seen : i64 0]
          [b : i64 0]
          [ok? : bool true]
          (while (< b facts.blocks.len)
            (begin
              (match (ir.compiler-ir-block-seq-ref facts.blocks b)
                [(ir.CompilerIrBlock.Block _ instrs)
                  (let
                    [i : i64 0]
                    (while (< i (ir.compiler-ir-instr-seq-count instrs))
                      (let
                        [instr : ir.CompilerIrInstr
                          (ir.compiler-ir-instr-seq-ref instrs i)]
                        (match (storage.marked-pointer instr)
                          [(ir.CompilerIrMaybeValue.No) unit]
                          [(ir.CompilerIrMaybeValue.Some _)
                            (set! seen (+ seen 1))
                            (set!
                              ok?
                              (and
                                ok?
                                (=
                                  expected
                                  (proof-code
                                    (storage.instruction-proof
                                      bases
                                      context
                                      facts
                                      instr)))))])
                        (set! i (+ i 1)))))])
              (set! b (+ b 1))))
          (and ok? (= seen 1)))])))

(define (authority-mutation-rejected? [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [canonical-functions : ir.CompilerIrFunctionSeq
      (ir.compiler-ir-function-seq1 (& (internal-callee)))]
    [empty : ir.CompilerIrExternSeq (ir.compiler-ir-extern-seq-empty)]
    [canonical : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-claims
        (ast.ast-node-pool-context-type-segment-bases pools)
        (ir.compiler-ir-type-pool-count pools)
        canonical-functions
        empty)]
    [authority : ir.CompilerIrReturnStorageAuthority
      (ir.compiler-ir-return-storage-authority-capture
        pools
        interns
        0
        canonical)]
    [actual : ir.CompilerIrFunctionSeq
      (ir.compiler-ir-function-seq1
        (&
          (irt.func
            (cond
              [(= mode 0)
                "function @make(output=%0:u64) -> u64 vars 1 abi return-storage internal-trailing arg 0 bytes 8 output SretValue result u64 params (u64) source (-> SretValue) {\nentry:\nreturn %0\n}"]
              [(= mode 1)
                "function @make(output=%0:u64) -> u64 vars 1 abi return-storage internal-leading arg 0 bytes 24 output SretValue result u64 params (u64) source (-> SretValue) {\nentry:\nreturn %0\n}"]
              [(= mode 2)
                "function @make(value=%0:i64, output=%1:u64) -> u64 vars 2 abi return-storage internal-trailing arg 1 bytes 24 output SretValue result u64 params (i64 u64) source (-> SretValue) {\nentry:\nreturn %1\n}"]
              [else
                "function @make(output=%0:u64) -> u64 vars 1 abi return-storage internal-trailing arg 0 bytes 24 output SretValue result u64 params (u64) source (-> SretValue) {\nentry:\nreturn %0\n}"]))))]
    [authority : ir.CompilerIrReturnStorageAuthority
      (if (>= mode 3)
        (match authority
          [(ir.CompilerIrReturnStorageAuthority.None)
            (ir.CompilerIrReturnStorageAuthority.None)]
          [(ir.CompilerIrReturnStorageAuthority.Invalid problem)
            (ir.CompilerIrReturnStorageAuthority.Invalid problem)]
          [(ir.CompilerIrReturnStorageAuthority.Captured boxed)
            (let
              [data : ir.CompilerIrReturnStorageAuthorityData
                (ir.compiler-ir-box-shared-view boxed)]
              (cond
                [(= mode 3)
                  (set! data.intern-generation (+ data.intern-generation 1))]
                [(= mode 4)
                  (set! data.stamp.revision (+ data.stamp.revision 1))]
                [(= mode 5) (set! data.target 1)]
                [else unit])
              (ir.CompilerIrReturnStorageAuthority.Captured (box data)))])
        authority)]
    [result : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-authorized
        pools
        interns
        0
        actual
        empty
        authority)]
    (string.eq
      result.problem
      (cond
        [(= mode 3) "stale return-storage source-name authority"]
        [(= mode 4) "stale return-storage type-pool authority"]
        [(= mode 5) "return-storage authority target mismatch"]
        [else "return-storage ABI differs from canonical lowering evidence"]))))

;; Unlike the independent mismatch fixtures, this models the actual producer:
;; the initial assertion and canonical-input record share one Box. Capture must
;; separate it before any later IR mutation.
(define (authority-box-isolated?) : bool
  (let
    [functions : ir.CompilerIrFunctionSeq
      (ir.compiler-ir-function-seq1 (& (internal-callee)))]
    [externs : ir.CompilerIrExternSeq (ir.compiler-ir-extern-seq-empty)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [canonical : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-claims
        (ast.ast-node-pool-context-type-segment-bases pools)
        (ir.compiler-ir-type-pool-count pools)
        functions
        externs)]
    [authority : ir.CompilerIrReturnStorageAuthority
      (ir.compiler-ir-return-storage-authority-capture
        pools
        interns
        0
        canonical)]
    (match (ir.compiler-ir-function-seq-ref functions 0)
      [(ir.CompilerIrFunction.Function _ _ _ _ _ abi)
        (match abi
          [(ir.CompilerIrFunctionAbi.ReturnStorage boxed)
            (let
              [contract : ir.CompilerIrReturnStorageAbi
                (ir.compiler-ir-box-shared-view boxed)]
              (set! contract.bytes 8)
              (set! (deref boxed) contract))]
          [_ unit])])
    (let
      [result : ir.CompilerIrReturnStorageIndex
        (ir.compiler-ir-return-storage-index-authorized
          pools
          interns
          0
          functions
          externs
          authority)]
      (string.eq
        result.problem
        "return-storage ABI differs from canonical lowering evidence"))))

(define (authority-snapshot-handoff?) : bool
  (let
    [functions : ir.CompilerIrFunctionSeq
      (ir.compiler-ir-function-seq1 (& (internal-callee)))]
    [externs : ir.CompilerIrExternSeq (ir.compiler-ir-extern-seq-empty)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [canonical : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-claims
        (ast.ast-node-pool-context-type-segment-bases pools)
        (ir.compiler-ir-type-pool-count pools)
        functions
        externs)]
    [authority : ir.CompilerIrReturnStorageAuthority
      (ir.compiler-ir-return-storage-authority-capture
        pools
        interns
        0
        canonical)]
    ;; A snapshot is another context over the same type storage and cursor:
    ;; the original authority remains valid through it.
    [snapshot : ast.AstNodePoolContext
      (ast.ast-node-pool-context-snapshot pools)]
    [through-snapshot : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-authorized
        snapshot
        interns
        0
        functions
        externs
        authority)]
    ;; A types-only copy is distinct storage with its own cursor. The
    ;; original authority is stale there until the checked handoff verifies
    ;; the identical canonical prefix and rehomes it.
    [copy : ast.AstNodePoolContext
      (ast.ast-node-pool-context-clone-types-only pools)]
    [before : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-authorized
        copy
        interns
        0
        functions
        externs
        authority)]
    [invalid-clone : ir.CompilerIrReturnStorageAuthority
      (ir.compiler-ir-clone-return-storage-authority
        copy
        (ir.compiler-ir-global-shared-view authority))]
    [after-invalid-clone : ir.CompilerIrReturnStorageIndex
      (ir.compiler-ir-return-storage-index-authorized
        copy
        interns
        0
        functions
        externs
        invalid-clone)]
    [published : ir.CompilerIrProgram
      (ir.compiler-ir-program-after-type-copy
        pools
        copy
        (ir.CompilerIrProgram.Program
          (ir.compiler-ir-global-seq-empty)
          functions
          externs
          authority))]
    [ok : bool
      (and
        (= through-snapshot.len 1)
        (= (string.string-length through-snapshot.problem) 0)
        (string.eq before.problem "stale return-storage type-pool authority")
        (string.eq
          after-invalid-clone.problem
          "stale return-storage type-pool authority")
        (match published
          [(ir.CompilerIrProgram.Program
              _
              current-functions
              current-externs
              current-authority)
            (let
              [after : ir.CompilerIrReturnStorageIndex
                (ir.compiler-ir-return-storage-index-authorized
                  copy
                  interns
                  0
                  current-functions
                  current-externs
                  current-authority)]
              (and
                (= after.len 1)
                (= (string.string-length after.problem) 0)
                (let
                  [declaration : ir.CompilerIrReturnStorageDeclaration
                    (ir.compiler-ir-array-shared-view after.declarations 0)]
                  (match declaration.storage
                    [(ir.CompilerIrReturnStorage.Some _) true]
                    [_ false]))))]))]
    (ast.ast-node-pool-context-destroy-storage! copy)
    ok))

(define (malformed-indirect-type-rejected?) : bool
  (let
    [source : ir.CompilerIrFunction
      (caller "" (private-body "%4 = call_c* %6([sret arg 0] %3) : u64"))]
    [context : ir.CompilerIrReturnStorageIndex (catalog 2)]
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    (match source
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks abi)
        (let
          [params : ir.CompilerIrParamSeq
            (ir.compiler-ir-param-seq-append-one
              (ir.compiler-ir-param-seq-empty)
              (ir.CompilerIrParam.Param
                "bad"
                (ast.AstType.CFunc
                  9223372036854775807
                  (ast.AstCFunctionMode.NonNull))
                6))]
          [facts : storage.StorageFacts
            (storage.facts bases params abi blocks vars)]
          [instruction : ir.CompilerIrInstr
            (irt.instr "%4 = call_c* %6([sret arg 0] %3) : u64")]
          (=
            (proof-code
              (storage.instruction-proof bases context facts instruction))
            -1))])))

(define (return-storage-proof-self-test) : i64
  (cond
    [(not (case? 1 "" (private-body "%4 = call make([sret arg 0] %3) : u64") 1))
      1]
    [(not (case? 0 "" (private-body "%4 = call make([sret arg 0] %3) : u64") 0))
      2]
    [(not
        (case? 3 "" (private-body "%4 = call make([sret arg 0] %3) : u64") -1))
      3]
    [(not
        (case?
          1
          ""
          "%3 = mov 42 : u64\n%4 = call make([sret arg 0] %3) : u64"
          -1))
      4]
    [(not (case? 1 "scalar=%3:u64" "%4 = call make([sret arg 0] %3) : u64" -1))
      5]
    [(not
        (case?
          1
          ""
          "%2 = alloc SretValue\n%3 = addr_of %2 storage 1\n%4 = call make([sret arg 0] %3) : u64"
          -1))
      6]
    [(not
        (case?
          1
          ""
          "%0 = alloc WrongValue\n%1 = alloc WrongValue\n%2 = alloc WrongValue\n%3 = addr_of %2 storage 3\n%4 = call make([sret arg 0] %3) : u64"
          -1))
      7]
    [(not
        (case?
          1
          ""
          (private-body
            "%5 = gep %3, 0 : u8\n%4 = call make([sret arg 0] %5) : u64")
          1))
      8]
    [(not
        (case?
          1
          ""
          (private-body
            "%5 = gep %3, 1 : u8\n%4 = call make([sret arg 0] %5) : u64")
          -1))
      9]
    [(not
        (case?
          1
          ""
          (private-body "%4 = call make([sret arg 1] 0, %3) : u64")
          -1))
      10]
    [(not
        (case?
          1
          ""
          (private-body "%4 = call make([sret arg 0] %3, 0) : u64")
          -1))
      11]
    [(not
        (case? 1 "" (private-body "%4 = call make([sret arg 0] %3) : f64") -1))
      12]
    [(not (case? 2 "" (private-body "%4 = call make([sret arg 0] %3) : u64") 1))
      13]
    [(not
        (case?
          2
          "f=%6:(CFunc non-null (-> SretValue))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          1))
      14]
    [(not
        (case?
          2
          "f=%6:(CFunc non-null (-> i64))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          -1))
      15]
    [(not
        (case?
          2
          "f=%6:u64"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          -1))
      16]
    [(not
        (case?
          2
          "f=%6:(CFunc nullable (-> SretValue))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          -1))
      17]
    [(not
        (case?
          2
          "f=%6:(CFunc non-null (-> SretValue))"
          (private-body "%4 = call* %6([sret arg 0] %3) : u64")
          -1))
      18]
    [(not
        (case?
          2
          "f=%6:u64"
          (private-body
            "%7 = cast %6 : u64 to (CFunc non-null (-> SretValue))\n%4 = call_c* %7([sret arg 0] %3) : u64")
          0))
      19]
    [(not
        (case?
          1
          ""
          (private-body
            "%5 = mov %3 : u64\n%4 = call make([sret arg 0] %5) : u64")
          1))
      20]
    ;; Adjacent independent slots do not establish an allocation extent.
    [(not
        (case?
          1
          ""
          "%0 = alloc SretValue\n%1 = alloc SretValue\n%2 = alloc SretValue\n%3 = addr_of %2\n%4 = call make([sret arg 0] %3) : u64"
          0))
      21]
    [(not
        (case?
          1
          ""
          (private-body
            "%5 = addr_of %1\n%4 = call make([sret arg 0] %3) : u64")
          -1))
      22]
    [(not
        (case?
          1
          ""
          (private-body
            "%5 = mov %0 : u64\n%4 = call make([sret arg 0] %3) : u64")
          -1))
      23]
    [(not
        (case?
          1
          ""
          "%0 = alloc SretValue\n%1 = alloc SretValue\n%2 = alloc SretValue\n%3 = addr_of %2 storage 4\n%4 = call make([sret arg 0] %3) : u64"
          -1))
      24]
    [(not (authority-mutation-rejected? 0)) 25]
    [(not (authority-mutation-rejected? 1)) 26]
    [(not (authority-mutation-rejected? 2)) 27]
    [(not (authority-mutation-rejected? 3)) 28]
    [(not (authority-mutation-rejected? 4)) 29]
    [(not (authority-mutation-rejected? 5)) 30]
    [(not (authority-box-isolated?)) 31]
    [(not (authority-snapshot-handoff?)) 32]
    [(not
        (case?
          4
          "f=%6:(CFunc non-null (-> SretValue))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          -1))
      33]
    [(not
        (case?
          5
          ""
          (private-body "%4 = call_c* @make([sret arg 0] %3) : u64")
          1))
      34]
    [(not
        (case?
          5
          ""
          (private-body
            "%6 = mov @make : (CFunc non-null (-> SretValue))\n%4 = call_c* %6([sret arg 0] %3) : u64")
          1))
      35]
    [(not
        (case? 5 "" (private-body "%4 = call make([sret arg 0] %3) : u64") -1))
      36]
    [(not
        (case?
          6
          ""
          (private-body "%4 = call_c* @make([sret arg 0] %3) : u64")
          -1))
      37]
    [(not
        (case?
          5
          "f=%6:(CFunc non-null (-> SretValue))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          1))
      38]
    [(not (malformed-indirect-type-rejected?)) 39]
    [(not
        (case?
          7
          "f=%6:(CFunc non-null (-> SretValue))"
          (private-body "%4 = call_c* %6([sret arg 0] %3) : u64")
          1))
      40]
    [(not (case? 7 "" (private-body "%4 = call make([sret arg 0] %3) : u64") 1))
      41]
    ;; A join of unspecified extents supplies no optimization proof; mixing
    ;; in a scalar address still rejects the output-storage claim.
    [(not
        (case?
          1
          ""
          "%0 = alloc SretValue\n%1 = addr_of %0\n%2 = select true, %1, %1 lanes 0 : u64\n%4 = call make([sret arg 0] %2) : u64"
          0))
      43]
    [(not
        (case?
          1
          "scalar=%3:u64"
          "%0 = alloc SretValue\n%1 = addr_of %0\n%2 = select true, %1, %3 lanes 0 : u64\n%4 = call make([sret arg 0] %2) : u64"
          -1))
      44]
    [else 42]))

(test
  return-storage-signatures-and-ranges
  (test.assert-i64-eq
    (return-storage-proof-self-test)
    42
    "return storage signatures and ranges"))

(test
  return-storage-lifetime-instantiation
  (let
    [types : (Array String 4)
      (array
        "(SretValue actual)"
        "(WrongValue actual)"
        "(SretValue actual extra)"
        "u64")]
    (for [mode (iterator.range 0 7)]
      (let
        [slot : String
          (clone
            (array-ref
              types
              (if (< mode 4)
                mode
                0)))]
        [result : String
          (clone
            (array-ref
              types
              (if (< mode 4)
                0
                (- mode 3))))]
        [body : String
          (str_cat.str-cat
            "%0 = alloc "
            (clone slot)
            "\n%1 = alloc "
            (clone slot)
            "\n%2 = alloc "
            slot
            "\n%3 = addr_of %2 storage 3\n%4 = call make([sret arg 0] %3) : "
            result)]
        (test.assert-true
          (case?
            8
            ""
            body
            (if (= mode 0)
              1
              -1))
          "lifetime instantiation preserves layout; nominal identity, arity and result representation remain exact")))))

(test
  return-storage-nested-lifetime-layout
  (let
    [types : (Array String 7)
      (array
        "(Tuple (& actual i64) (SretValue actual))"
        "(Tuple (&mut actual i64) (SretValue actual))"
        "(Tuple (& actual f64) (SretValue actual))"
        "(Tuple (& actual i64) (WrongValue actual))"
        "(Tuple (& actual i64) (SretValue actual extra))"
        "(Tuple (& actual i64))"
        "(Array (& actual i64) 2)")]
    (for [mode (iterator.range 0 7)]
      (match (irt.func
        "function @left() -> (Tuple (& declared i64) (SretValue declared)) vars 0 {\nentry:\nreturn\n}")
        [(ir.CompilerIrFunction.Function _ _ left _ _ _)
          (match (irt.func
            (str_cat.str-cat
              "function @right() -> "
              (clone (array-ref types mode))
              " vars 0 {\nentry:\nreturn\n}"))
            [(ir.CompilerIrFunction.Function _ _ right _ _ _)
              (test.assert-true
                (=
                  (= mode 0)
                  (storage.layout-type-equal?
                    (ast.ast-node-pool-reader-type-segment-bases)
                    left
                    right
                    64))
                "nested lifetime substitution cannot change runtime layout or reference mutability")])]))))