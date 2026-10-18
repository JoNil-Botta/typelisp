;; Proofs for the untrusted Sret call-argument role. Declarations are taken
;; from the current IR revision; storage facts are derived from the caller.
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as names)

(defenum ReturnStorageProof
  (Unavailable)
  (Invalid String)
  (Known (Box ir.CompilerIrReturnStorageAbi)))

(defenum StorageRange
  (Unknown)
  (Unproven)
  (Range i64 i64))

(defstruct StorageFacts
  (bases i64)
  (blocks ir.CompilerIrBlockSeq)
  (params ir.CompilerIrParamSeq)
  (abi ir.CompilerIrFunctionAbi)
  (definition-block (__tl_dyn-array i64))
  (definition-pos (__tl_dyn-array i64))
  (definition-count (__tl_dyn-array i64))
  (storage-owner (__tl_dyn-array i64))
  (storage-words (__tl_dyn-array i64))
  (storage-invalid (__tl_dyn-array bool)))

(define (facts
  [bases : i64]
  [params : ir.CompilerIrParamSeq]
  [abi : ir.CompilerIrFunctionAbi]
  [blocks : ir.CompilerIrBlockList]
  [vars : i64]) : StorageFacts
  (let
    [dense : ir.CompilerIrBlockSeq (ir.compiler-ir-block-list-seq blocks)]
    [out : StorageFacts
      (StorageFacts
        bases
        dense
        params
        abi
        (__tl_make-array i64 vars)
        (__tl_make-array i64 vars)
        (__tl_make-array i64 vars)
        (__tl_make-array i64 vars)
        (__tl_make-array i64 vars)
        (__tl_make-array bool vars))]
    [i : i64 0]
    (while (< i out.params.len)
      (begin
        (match (ir.compiler-ir-param-seq-ref out.params i)
          [(ir.CompilerIrParam.Param _ _ var)
            (when
              (and (>= var 0) (< var vars))
              (set!
                (array-ref out.definition-count var)
                (+ 1 (array-ref out.definition-count var)))
              (set! (array-ref out.definition-block var) -1)
              (set! (array-ref out.definition-pos var) i))])
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i out.blocks.len)
      (begin
        (match (ir.compiler-ir-block-seq-ref out.blocks i)
          [(ir.CompilerIrBlock.Block _ instrs)
            (let
              [p : i64 0]
              (while (< p (ir.compiler-ir-instr-seq-count instrs))
                (let
                  [instr : ir.CompilerIrInstr
                    (ir.compiler-ir-instr-seq-ref instrs p)]
                  [dst : i64 (ir.compiler-ir-instr-dst instr)]
                  (when
                    (and
                      (>= dst 0)
                      (< dst vars)
                      (not (identity-incoming-move? (& out) instr)))
                    (set!
                      (array-ref out.definition-count dst)
                      (+ 1 (array-ref out.definition-count dst)))
                    (set! (array-ref out.definition-block dst) i)
                    (set! (array-ref out.definition-pos dst) p))
                  (set! p (+ p 1)))))])
        (set! i (+ i 1))))
    (storage-facts! (&mut out))
    out))

;; A positive AddrOf extent declares one object over exactly these slots.
;; Adjacency alone never establishes ownership of an earlier independent slot.
;; The declaration must sit immediately after its complete physical run.
(define (storage-declare!
  [facts : (&mut facts StorageFacts)]
  [instrs : (& instrs ir.CompilerIrInstrSeq)]
  [position : i64]
  [dst : i64]
  [source : i64]
  [words : i64]) : unit
  (when
    (single? facts dst)
    (set! (array-ref facts.storage-words dst) words)
    (when
      (not (= words 0))
      (if (or
        (< words 0)
        (> words position)
        (> words (+ source 1))
        (not (single? facts source))
        (> words 1152921504606846975))
        (set! (array-ref facts.storage-invalid dst) true)
        (let
          [last : ir.CompilerIrInstr
            (ir.compiler-ir-instr-seq-ref instrs (- position 1))]
          [i : i64 0]
          [valid? : bool true]
          (while (< i words)
            (let
              [slot : i64 (- source i)]
              [part : ir.CompilerIrInstr
                (ir.compiler-ir-instr-seq-ref instrs (- (- position 1) i))]
              [same? : bool
                (match part
                  [(ir.CompilerIrInstr.Alloc var ty)
                    (and
                      (= var slot)
                      (single? facts slot)
                      (match (ir.compiler-ir-global-shared-view last)
                        [(ir.CompilerIrInstr.Alloc _ expected)
                          (ast.ast-type-eq-with-seg-bases?
                            facts.bases
                            ty
                            expected)]
                        [_ false]))]
                  [_ false])]
              (unless same? (set! valid? false))
              (set! i (+ i 1))))
          (if (not valid?)
            (set! (array-ref facts.storage-invalid dst) true)
            (begin
              (set! i 0)
              (while (< i words)
                (let
                  [slot : i64 (- source i)]
                  [previous : i64 (array-ref facts.storage-owner slot)]
                  (when
                    (and (> previous 0) (not (= previous (+ dst 1))))
                    (set! (array-ref facts.storage-invalid (- previous 1)) true)
                    (set! (array-ref facts.storage-invalid dst) true))
                  (set! (array-ref facts.storage-owner slot) (+ dst 1))
                  (set! i (+ i 1)))))))))))

;; A claimed storage slot cannot simultaneously be an independent scalar
;; value. Ordinary aliases created with AddrOf are checked separately below.
(define (storage-value-use!
  [facts : (&mut facts StorageFacts)]
  [_role : ir.CompilerIrOperandRole]
  [value : ir.CompilerIrValue]) : unit
  (match value
    [(ir.CompilerIrValue.Var var)
      (when
        (and (>= var 0) (< var (array-length facts.storage-owner)))
        (let
          [owner : i64 (array-ref facts.storage-owner var)]
          (when
            (> owner 0)
            (set! (array-ref facts.storage-invalid (- owner 1)) true))))]
    [_ unit]))

(define (storage-facts! [facts : (&mut facts StorageFacts)]) : unit
  (let
    [pass : i64 0]
    (while (< pass 2)
      (let
        [b : i64 0]
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
                      (if (= pass 0)
                        (match (ir.compiler-ir-global-shared-view instr)
                          [(ir.CompilerIrInstr.AddrOf dst source words)
                            (storage-declare! facts instrs i dst source words)]
                          [_ unit])
                        (match (ir.compiler-ir-global-shared-view instr)
                          [(ir.CompilerIrInstr.AddrOf dst source _)
                            (when
                              (and
                                (>= source 0)
                                (< source (array-length facts.storage-owner)))
                              (let
                                [owner : i64
                                  (array-ref facts.storage-owner source)]
                                (when
                                  (and (> owner 0) (not (= owner (+ dst 1))))
                                  (set!
                                    (array-ref
                                      facts.storage-invalid
                                      (- owner 1))
                                    true))))]
                          [_
                            (ir.compiler-ir-instr-visit-uses
                              instr
                              storage-value-use!
                              facts)]))
                      (set! i (+ i 1)))))])
            (set! b (+ b 1))))
        (set! pass (+ pass 1))))))

(define (single? [facts : (& facts StorageFacts)] [var : i64]) : bool
  (and
    (>= var 0)
    (< var (array-length facts.definition-count))
    (= (array-ref facts.definition-count var) 1)))

(define (structural-address-cast? [from : ast.AstType] [to : ast.AstType]) : bool
  (and
    (match to
      [(ast.AstType.U64) true]
      [_ false])
    (match from
      [(ast.AstType.Tuple _) true]
      [(ast.AstType.Array _ _) true]
      [_ false])))

(define (incoming-range [facts : (& facts StorageFacts)] [var : i64]) : StorageRange
  (let
    [facts : StorageFacts
      (owned_view.compiler-owned-reference-shared-view facts)]
    (match facts.abi
      [(ir.CompilerIrFunctionAbi.ReturnStorage boxed)
        (let
          [abi : ir.CompilerIrReturnStorageAbi
            (ir.compiler-ir-box-shared-view boxed)]
          (if (and (>= abi.index 0) (< abi.index facts.params.len))
            (match (ir.compiler-ir-param-seq-ref facts.params abi.index)
              [(ir.CompilerIrParam.Param _ _ hidden)
                (if (= hidden var)
                  (StorageRange.Range (- 0 (+ var 1)) abi.bytes)
                  (StorageRange.Unknown))])
            (StorageRange.Unknown)))]
      [_ (StorageRange.Unknown)])))

;; Tail-recursion lowering can leave an exact u64 self assignment of the
;; hidden output parameter. It changes neither its bits nor its declaration;
;; other writes, including narrower moves and copies through aliases, still
;; invalidate the single-definition evidence.
(define (identity-incoming-move?
  [facts : (& StorageFacts)]
  [instr : ir.CompilerIrInstr]) : bool
  (match instr
    [(ir.CompilerIrInstr.Mov
        dst
        (ir.CompilerIrValue.Var source)
        (ast.AstType.U64))
      (and
        (= dst source)
        (match (incoming-range facts dst)
          [(StorageRange.Range _ _) true]
          [_ false]))]
    [_ false]))

(define (addressed-range
  [facts : (& facts StorageFacts)]
  [dst : i64]
  [source : i64]) : StorageRange
  (if (or (not (single? facts dst)) (not (single? facts source)))
    (StorageRange.Unknown)
    (let
      [words : i64 (array-ref facts.storage-words dst)]
      (cond
        [(array-ref facts.storage-invalid dst) (StorageRange.Unknown)]
        [(= words 0) (StorageRange.Unproven)]
        [(> words 0) (StorageRange.Range source (* words 8))]
        [else (StorageRange.Unknown)]))))

;; Call-site lifetimes instantiate declaration-local binders without changing
;; layout. Keep nominal identities, lifetime arity, mutability and all runtime
;; type structure exact. Declaration/authority identity remains stricter.
(define (layout-type-ids-equal?
  [bases : i64]
  [depth : i64]
  [left : i64]
  [right : i64]) : bool
  (or
    (= left right)
    (layout-type-equal?
      bases
      (ast.ast-type-segment-bases-get bases left)
      (ast.ast-type-segment-bases-get bases right)
      depth)))

(define (layout-type-equal?
  [bases : i64]
  [left : ast.AstType]
  [right : ast.AstType]
  [depth : i64]) : bool
  (if (<= depth 0)
    false
    (match (& left)
      [(ast.AstType.StructArgs name lifetimes)
        (match right
          [(ast.AstType.StructArgs other arguments)
            (and
              (= name other)
              (=
                (ast.ast-lifetime-list-len (deref lifetimes))
                (ast.ast-lifetime-list-len (deref arguments))))]
          [_ false])]
      [(ast.AstType.EnumArgs name lifetimes)
        (match right
          [(ast.AstType.EnumArgs other arguments)
            (and
              (= name other)
              (=
                (ast.ast-lifetime-list-len (deref lifetimes))
                (ast.ast-lifetime-list-len (deref arguments))))]
          [_ false])]
      [(ast.AstType.Ref _ inner)
        (match right
          [(ast.AstType.Ref _ other)
            (layout-type-ids-equal? bases (- depth 1) inner other)]
          [_ false])]
      [(ast.AstType.MutRef _ inner)
        (match right
          [(ast.AstType.MutRef _ other)
            (layout-type-ids-equal? bases (- depth 1) inner other)]
          [_ false])]
      [_
        (ast.ast-type-children-eq?
          left
          right
          layout-type-ids-equal?
          bases
          (- depth 1))])))

(define (range-output?
  [facts : (& facts StorageFacts)]
  [root : i64]
  [output : ast.AstType]) : bool
  (if (< root 0)
    (let
      [facts : StorageFacts
        (owned_view.compiler-owned-reference-shared-view facts)]
      (match facts.abi
        [(ir.CompilerIrFunctionAbi.ReturnStorage boxed)
          (let
            [abi : ir.CompilerIrReturnStorageAbi
              (ir.compiler-ir-box-shared-view boxed)]
            (layout-type-equal? facts.bases output abi.output 64))]
        [_ false]))
    (if (not (single? facts root))
      false
      (let
        [block : i64 (array-ref facts.definition-block root)]
        [position : i64 (array-ref facts.definition-pos root)]
        (if (< block 0)
          false
          (match (ir.compiler-ir-block-seq-ref facts.blocks block)
            [(ir.CompilerIrBlock.Block _ instrs)
              (match (ir.compiler-ir-instr-seq-ref instrs position)
                [(ir.CompilerIrInstr.Alloc _ ty)
                  (layout-type-equal? facts.bases output ty 64)]
                [_ false])]))))))

(define (range-equal [left : StorageRange] [right : StorageRange]) : StorageRange
  (match left
    ;; Missing extent evidence stays missing across a join. This never grants
    ;; a range, an alias identity or permission to use a callee ABI proof.
    [(StorageRange.Unproven)
      (match right
        [(StorageRange.Unproven) (StorageRange.Unproven)]
        [_ (StorageRange.Unknown)])]
    [(StorageRange.Range root bytes)
      (match right
        [(StorageRange.Range other count)
          (if (and (= root other) (= bytes count))
            (StorageRange.Range root bytes)
            (StorageRange.Unknown))]
        [_ (StorageRange.Unknown)])]
    [_ (StorageRange.Unknown)]))

;; The budget is shared across branches, not reset at each recursive edge.
;; Exhaustion supplies no proof. Phi/Select admit only one exact range and
;; GEP admits only zero offsets; interior pointers cannot borrow root capacity.
(define (range
  [facts : (& facts StorageFacts)]
  [value : ir.CompilerIrValue]
  [budget : (&mut budget i64)]) : StorageRange
  (if (<= (deref budget) 0)
    (StorageRange.Unknown)
    (begin
      (set! (deref budget) (- (deref budget) 1))
      (match value
        [(ir.CompilerIrValue.Var var)
          (if (not (single? facts var))
            (StorageRange.Unknown)
            (let
              [block : i64 (array-ref facts.definition-block var)]
              [position : i64 (array-ref facts.definition-pos var)]
              (if (< block 0)
                (incoming-range facts var)
                (match (ir.compiler-ir-block-seq-ref facts.blocks block)
                  [(ir.CompilerIrBlock.Block _ instrs)
                    (match (ir.compiler-ir-instr-seq-ref instrs position)
                      [(ir.CompilerIrInstr.AddrOf dst source _storage-words)
                        (addressed-range facts dst source)]
                      [(ir.CompilerIrInstr.Mov _ source _)
                        (range facts source budget)]
                      [(ir.CompilerIrInstr.Cast _ source from to)
                        (if (structural-address-cast? from to)
                          (range facts source budget)
                          (StorageRange.Unknown))]
                      [(ir.CompilerIrInstr.Gep _ base offset _)
                        (if (match offset
                          [(ir.CompilerIrValue.I64 n) (= n 0)]
                          [_ false])
                          (range facts base budget)
                          (StorageRange.Unknown))]
                      [(ir.CompilerIrInstr.Phi _ inputs _)
                        (if (<= inputs.len 0)
                          (StorageRange.Unknown)
                          (let
                            [first : ir.CompilerIrPhiInput
                              (ir.compiler-ir-phi-input-seq-ref inputs 0)]
                            [found : StorageRange
                              (range facts first.value budget)]
                            [i : i64 1]
                            (while (and (< i inputs.len) (> (deref budget) 0))
                              (let
                                [input : ir.CompilerIrPhiInput
                                  (ir.compiler-ir-phi-input-seq-ref inputs i)]
                                (set!
                                  found
                                  (range-equal
                                    found
                                    (range facts input.value budget)))
                                (set! i (+ i 1))))
                            (if (= i inputs.len)
                              found
                              (StorageRange.Unknown))))]
                      [(ir.CompilerIrInstr.Select boxed)
                        (let
                          [left
                            (ir.compiler-ir-box-field-shared-view boxed on-true)]
                          [right
                            (ir.compiler-ir-box-field-shared-view
                              boxed
                              on-false)]
                          (range-equal
                            (range facts left budget)
                            (range facts right budget)))]
                      [_ (StorageRange.Unknown)])]))))]
        [_ (StorageRange.Unknown)]))))

(define (call-shape
  [bases : i64]
  [args : (& args ir.CompilerIrCallArgs)]
  [result : ast.AstType]
  [declaration : (Box ir.CompilerIrReturnStorageAbi)]) : ReturnStorageProof
  (let
    [args : ir.CompilerIrCallArgs
      (owned_view.compiler-owned-reference-shared-view args)]
    [abi : ir.CompilerIrReturnStorageAbi
      (ir.compiler-ir-box-shared-view declaration)]
    (match args
      [(ir.CompilerIrCallArgs.Sret values index)
        (cond
          [(not (= index abi.index))
            (ReturnStorageProof.Invalid
              "sret argument position differs from callee ABI")]
          [(not
              (=
                (array-length values)
                (ast.ast-type-list-len abi.physical-params)))
            (ReturnStorageProof.Invalid
              "sret physical argument count differs from callee ABI")]
          [(not (layout-type-equal? bases result abi.physical-result 64))
            (ReturnStorageProof.Invalid
              "sret physical result differs from callee ABI")]
          [else (ReturnStorageProof.Known declaration)])]
      [_ (ReturnStorageProof.Unavailable)])))

(define (direct
  [bases : i64]
  [catalog : (& catalog ir.CompilerIrReturnStorageIndex)]
  [callee : i64]
  [expected-c : i64]
  [args : (& args ir.CompilerIrCallArgs)]
  [result : ast.AstType]) : ReturnStorageProof
  (if (> (string.string-length catalog.problem) 0)
    (ReturnStorageProof.Invalid (string.copy catalog.problem))
    (match (names.get catalog.names callee)
      [(names.LookupMissing) (ReturnStorageProof.Unavailable)]
      [(names.LookupFound index)
        (if (or (< index 0) (>= index catalog.len))
          (ReturnStorageProof.Invalid "ambiguous sret callee declaration")
          (let
            [decl : ir.CompilerIrReturnStorageDeclaration
              (ir.compiler-ir-array-shared-view catalog.declarations index)]
            (if (or
              (and (>= expected-c 0) (not (= decl.c-abi? (> expected-c 0))))
              (not
                (match (ir.compiler-ir-global-shared-view decl.signature)
                  [(ast.AstType.CFunc _ mode)
                    (and
                      (= expected-c 2)
                      (match mode
                        [(ast.AstCFunctionMode.NonNull) true]
                        [(ast.AstCFunctionMode.UnsafeNonNull) true]
                        [_ false]))]
                  [_ (not (= expected-c 2))])))
              (ReturnStorageProof.Invalid
                "sret callee uses a different calling convention")
              (match decl.storage
                [(ir.CompilerIrReturnStorage.Some abi)
                  (call-shape bases args result abi)]
                [(ir.CompilerIrReturnStorage.None)
                  (if (or
                    decl.c-abi?
                    (match (& decl.signature)
                      [(ast.AstType.Func _ _) true]
                      [_ false]))
                    ;; A foreign declaration can lack a lowered aggregate
                    ;; contract (for example a variadic signature). Its source
                    ;; result still disproves a forged scalar sret claim.
                    (match (ir.compiler-ir-return-storage-foreign-signature
                      bases
                      decl.signature)
                      [(ast.AstType.Func _ ret-id)
                        (let
                          [ret : ast.AstType
                            (ast.ast-type-segment-bases-get bases ret-id)]
                          (if (ir.compiler-ir-return-storage-type? ret)
                            (ReturnStorageProof.Unavailable)
                            (ReturnStorageProof.Invalid
                              "sret callee does not return an inline aggregate")))]
                      [_
                        (ReturnStorageProof.Invalid
                          "sret callee has a malformed foreign signature")])
                    (ReturnStorageProof.Invalid
                      "sret callee has no return-storage convention"))]))))])))

(define (contract-equal?
  [bases : i64]
  [left : (& left ir.CompilerIrReturnStorageAbi)]
  [right : (& right ir.CompilerIrReturnStorageAbi)]) : bool
  (let
    [left : ir.CompilerIrReturnStorageAbi
      (owned_view.compiler-owned-reference-shared-view left)]
    [right : ir.CompilerIrReturnStorageAbi
      (owned_view.compiler-owned-reference-shared-view right)]
    [count : i64 (ast.ast-type-list-len left.physical-params)]
    [i : i64 0]
    (and
      (= left.index right.index)
      (= left.bytes right.bytes)
      (= left.alignment right.alignment)
      (string.eq
        (ir.compiler-ir-return-storage-convention-render left.convention)
        (ir.compiler-ir-return-storage-convention-render right.convention))
      (ast.ast-type-eq-with-seg-bases? bases left.output right.output)
      (ast.ast-type-eq-with-seg-bases?
        bases
        left.physical-result
        right.physical-result)
      (ast.ast-type-eq-with-seg-bases?
        bases
        left.source-signature
        right.source-signature)
      (= count (ast.ast-type-list-len right.physical-params))
      (begin
        (while (< i count)
          (unless
            (ast.ast-type-eq-with-seg-bases?
              bases
              (ast.ast-type-segment-bases-get
                bases
                (ast.ast-type-list-get
                  left.physical-params
                  i
                  (ast.ast-type-id-fallback)))
              (ast.ast-type-segment-bases-get
                bases
                (ast.ast-type-list-get
                  right.physical-params
                  i
                  (ast.ast-type-id-fallback))))
            (return false))
          (set! i (+ i 1)))
        true))))

(define (storage-equal?
  [bases : i64]
  [left : (& ir.CompilerIrReturnStorage)]
  [right : (& ir.CompilerIrReturnStorage)]) : bool
  (match left
    [(ir.CompilerIrReturnStorage.None)
      (match right
        [(ir.CompilerIrReturnStorage.None) true]
        [_ false])]
    [(ir.CompilerIrReturnStorage.Some a)
      (match right
        [(ir.CompilerIrReturnStorage.Some b) (contract-equal? bases a b)]
        [_ false])]))

(define (function-abi-equal?
  [bases : i64]
  [left : ir.CompilerIrFunctionAbi]
  [right : ir.CompilerIrFunctionAbi]) : bool
  (match left
    [(ir.CompilerIrFunctionAbi.Ordinary)
      (match right
        [(ir.CompilerIrFunctionAbi.Ordinary) true]
        [_ false])]
    [(ir.CompilerIrFunctionAbi.ReturnStorage a)
      (match right
        [(ir.CompilerIrFunctionAbi.ReturnStorage b)
          (contract-equal? bases (deref a) (deref b))]
        [_ false])]
    [(ir.CompilerIrFunctionAbi.SpmdPrivate a)
      (match right
        [(ir.CompilerIrFunctionAbi.SpmdPrivate b)
          (ir.compiler-ir-spmd-private-abi-eq? bases (deref a) (deref b))]
        [_ false])]))

;; Only a canonical non-null CFunc value signature establishes an indirect C
;; calling convention. Consumers must not supply a type manufactured by a raw
;; cast. An erased/unknown function value supplies no storage-reuse proof.
(define (indirect-c
  [bases : i64]
  [catalog : (& catalog ir.CompilerIrReturnStorageIndex)]
  [callee-type : ast.AstType]
  [args : (& args ir.CompilerIrCallArgs)]
  [result : ast.AstType]) : ReturnStorageProof
  (let
    [budget : i64 4096]
    (when
      (> (string.string-length catalog.problem) 0)
      (return
        (ReturnStorageProof.Invalid
          "invalid return-storage declaration catalog")))
    (when (< catalog.type-count 0) (return (ReturnStorageProof.Unavailable)))
    (unless
      (ir.compiler-ir-return-storage-type-valid?
        bases
        catalog.type-count
        (ir.compiler-ir-global-shared-view callee-type)
        (&mut budget)
        64)
      (return
        (ReturnStorageProof.Invalid "invalid indirect sret type identity")))
    (match callee-type
      [(ast.AstType.CFunc signature-id mode)
        (if (match mode
          [(ast.AstCFunctionMode.NonNull) true]
          [(ast.AstCFunctionMode.UnsafeNonNull) true]
          [_ false])
          (let
            [signature : ast.AstType
              (ast.ast-type-segment-bases-get bases signature-id)]
            [found : ReturnStorageProof (ReturnStorageProof.Unavailable)]
            [i : i64 0]
            (match (ir.compiler-ir-global-shared-view signature)
              [(ast.AstType.Func _ result-id)
                (let
                  [source-result : ast.AstType
                    (ast.ast-type-segment-bases-get bases result-id)]
                  (if (not (ir.compiler-ir-return-storage-type? source-result))
                    (ReturnStorageProof.Invalid
                      "indirect sret signature does not return an inline aggregate")
                    (begin
                      (while (< i catalog.len)
                        (let
                          [decl : ir.CompilerIrReturnStorageDeclaration
                            (ir.compiler-ir-array-shared-view
                              catalog.declarations
                              i)]
                          (when
                            (and
                              decl.c-abi?
                              (ast.ast-type-eq-with-seg-bases?
                                bases
                                (ir.compiler-ir-global-shared-view signature)
                                (ir.compiler-ir-return-storage-foreign-signature
                                  bases
                                  decl.signature)))
                            (match decl.storage
                              [(ir.CompilerIrReturnStorage.None) unit]
                              [(ir.CompilerIrReturnStorage.Some abi)
                                (match (ir.compiler-ir-global-shared-view found)
                                  [(ReturnStorageProof.Known previous)
                                    (unless
                                      (contract-equal?
                                        bases
                                        (deref previous)
                                        (deref abi))
                                      (return
                                        (ReturnStorageProof.Invalid
                                          "conflicting indirect sret ABI declarations")))]
                                  [_
                                    (set! found (ReturnStorageProof.Known abi))])]))
                          (set! i (+ i 1))))
                      (match found
                        [(ReturnStorageProof.Known abi)
                          (call-shape bases args result abi)]
                        [_ (ReturnStorageProof.Unavailable)]))))]
              [_
                (ReturnStorageProof.Invalid
                  "indirect sret callee has a malformed CFunc signature")]))
          (ReturnStorageProof.Invalid
            "indirect sret requires a non-null CFunc signature"))]
      [_ (ReturnStorageProof.Unavailable)])))

(defenum CalleeEvidence
  (Unknown)
  (Named i64)
  (ExternalValue i64)
  (Typed ast.AstType))

(define (callee-evidence
  [facts : (& facts StorageFacts)]
  [value : ir.CompilerIrValue]
  [fuel : i64]) : CalleeEvidence
  (if (<= fuel 0)
    (CalleeEvidence.Unknown)
    (match value
      [(ir.CompilerIrValue.Function name) (CalleeEvidence.Named name)]
      [(ir.CompilerIrValue.Global name) (CalleeEvidence.ExternalValue name)]
      [(ir.CompilerIrValue.Var var)
        (if (not (single? facts var))
          (CalleeEvidence.Unknown)
          (let
            [block : i64 (array-ref facts.definition-block var)]
            [position : i64 (array-ref facts.definition-pos var)]
            (if (< block 0)
              (match (ir.compiler-ir-param-seq-ref facts.params position)
                [(ir.CompilerIrParam.Param _ ty _) (CalleeEvidence.Typed ty)])
              (match (ir.compiler-ir-block-seq-ref facts.blocks block)
                [(ir.CompilerIrBlock.Block _ instrs)
                  (match (ir.compiler-ir-instr-seq-ref instrs position)
                    [(ir.CompilerIrInstr.Mov _ source _)
                      (callee-evidence facts source (- fuel 1))]
                    ;; A cast or raw load may produce the right physical bits
                    ;; without preserving a callable declaration contract.
                    [_ (CalleeEvidence.Unknown)])]))))]
      [_ (CalleeEvidence.Unknown)])))

(define (indirect
  [bases : i64]
  [catalog : (& catalog ir.CompilerIrReturnStorageIndex)]
  [facts : (& facts StorageFacts)]
  [value : ir.CompilerIrValue]
  [c? : bool]
  [args : (& args ir.CompilerIrCallArgs)]
  [result : ast.AstType]) : ReturnStorageProof
  (match (callee-evidence facts value 64)
    [(CalleeEvidence.Named name)
      (direct
        bases
        catalog
        name
        (if c?
          1
          0)
        args
        result)]
    [(CalleeEvidence.ExternalValue name)
      (if c?
        (direct bases catalog name 2 args result)
        ;; A language closure stored in an ordinary global has no captured C
        ;; contract. Never infer its environment/callable identity here.
        (ReturnStorageProof.Unavailable))]
    [(CalleeEvidence.Typed ty)
      (if c?
        (match (& ty)
          [(ast.AstType.CFunc _ _) (indirect-c bases catalog ty args result)]
          [_
            (ReturnStorageProof.Invalid
              "indirect C sret callee lacks a CFunc signature")])
        (match ty
          [(ast.AstType.CFunc _ _)
            (ReturnStorageProof.Invalid
              "CFunc sret callee uses the internal calling convention")]
          [_ (ReturnStorageProof.Unavailable)]))]
    [_ (ReturnStorageProof.Unavailable)]))

(define (instruction-contract
  [bases : i64]
  [catalog : (& catalog ir.CompilerIrReturnStorageIndex)]
  [facts : (& facts StorageFacts)]
  [instr : (& instr ir.CompilerIrInstr)]) : ReturnStorageProof
  (if (> (string.string-length catalog.problem) 0)
    (ReturnStorageProof.Invalid "invalid return-storage declaration catalog")
    (let
      [instr : ir.CompilerIrInstr
        (owned_view.compiler-owned-reference-shared-view instr)]
      (match instr
        [(ir.CompilerIrInstr.Call _ name args result)
          (direct bases catalog name -1 args result)]
        [(ir.CompilerIrInstr.CallIndirect _ callee args result)
          (indirect bases catalog facts callee false args result)]
        [(ir.CompilerIrInstr.CallIndirectC _ callee args result)
          (indirect bases catalog facts callee true args result)]
        [_ (ReturnStorageProof.Unavailable)]))))

(define (marked-pointer [instr : (& instr ir.CompilerIrInstr)]) : ir.CompilerIrMaybeValue
  (let
    [instr : ir.CompilerIrInstr
      (owned_view.compiler-owned-reference-shared-view instr)]
    [args : ir.CompilerIrCallArgs
      (match instr
        [(ir.CompilerIrInstr.Call _ _ args _) args]
        [(ir.CompilerIrInstr.CallIndirect _ _ args _) args]
        [(ir.CompilerIrInstr.CallIndirectC _ _ args _) args]
        [_ (ir.CompilerIrCallArgs.Nil)])]
    (match args
      [(ir.CompilerIrCallArgs.Sret values index)
        (if (and (>= index 0) (< index (array-length values)))
          (ir.CompilerIrMaybeValue.Some
            (ir.compiler-ir-array-shared-view values index))
          (ir.CompilerIrMaybeValue.No))]
      [_ (ir.CompilerIrMaybeValue.No)])))

(define (instruction-proof
  [bases : i64]
  [catalog : (& catalog ir.CompilerIrReturnStorageIndex)]
  [facts : (& facts StorageFacts)]
  [instr : (& instr ir.CompilerIrInstr)]) : ReturnStorageProof
  (match (marked-pointer instr)
    [(ir.CompilerIrMaybeValue.No) (ReturnStorageProof.Unavailable)]
    [(ir.CompilerIrMaybeValue.Some pointer)
      (let
        [budget : i64 256]
        [storage : StorageRange (range facts pointer (&mut budget))]
        (match storage
          [(StorageRange.Unproven) (ReturnStorageProof.Unavailable)]
          [(StorageRange.Unknown)
            (if (<= budget 0)
              (ReturnStorageProof.Unavailable)
              (ReturnStorageProof.Invalid
                "sret argument is not a proven inline output range"))]
          [(StorageRange.Range root bytes)
            (match (instruction-contract bases catalog facts instr)
              [(ReturnStorageProof.Known boxed)
                (let
                  [abi : ir.CompilerIrReturnStorageAbi
                    (ir.compiler-ir-box-shared-view boxed)]
                  (cond
                    [(not (range-output? facts root abi.output))
                      (ReturnStorageProof.Invalid
                        "sret allocation type differs from callee output")]
                    [(< bytes abi.bytes)
                      (ReturnStorageProof.Invalid
                        "sret output range is smaller than callee ABI")]
                    [(> abi.alignment 8) (ReturnStorageProof.Unavailable)]
                    [else (ReturnStorageProof.Known boxed)]))]
              [(ReturnStorageProof.Invalid message)
                (ReturnStorageProof.Invalid message)]
              [(ReturnStorageProof.Unavailable)
                (ReturnStorageProof.Unavailable)])]))]))