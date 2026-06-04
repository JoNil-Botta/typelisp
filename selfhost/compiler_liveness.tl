;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis (#553).
;;
;; This module keeps the selfhost liveness pass deterministic while storing
;; integer live sets as compact bitsets keyed by dense IR variable ids.
(import "../stdlib/io.tl")

(import "compiler_ir_types.tl")

(defenum CompilerLiveI64Set
  (CompilerLiveI64Nil)
  (CompilerLiveI64Cons i64 CompilerLiveI64Set))

(defenum CompilerLiveLabelSet
  (CompilerLiveLabelNil)
  (CompilerLiveLabelCons String CompilerLiveLabelSet))

(defenum CompilerLiveInstrSetList
  (CompilerLiveInstrSetNil)
  (CompilerLiveInstrSetCons CompilerLiveI64Set CompilerLiveInstrSetList))

(defenum CompilerLiveBlock
  (CompilerLiveBlock
    String
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveLabelSet
    CompilerLiveInstrSetList))

(defenum CompilerLiveBlockList
  (CompilerLiveBlockNil)
  (CompilerLiveBlockCons CompilerLiveBlock CompilerLiveBlockList))

(defenum CompilerFunctionLiveness
  (CompilerFunctionLiveness CompilerLiveBlockList))

(defenum CompilerLiveMaybeBlock
  (CompilerLiveNoBlock)
  (CompilerLiveSomeBlock CompilerLiveBlock))

(defenum CompilerLiveMaybeInstr
  (CompilerLiveNoInstr)
  (CompilerLiveSomeInstr CompilerIrInstr))

(defenum CompilerLiveMaybeIrBlock
  (CompilerLiveNoIrBlock)
  (CompilerLiveSomeIrBlock CompilerIrBlock))

(defenum CompilerLiveUseDef
  (CompilerLiveUseDef CompilerLiveI64Set CompilerLiveI64Set))

(defenum CompilerLiveBlockListStep
  (CompilerLiveBlockListStep CompilerLiveBlockList bool))

(defenum CompilerLiveInstrScan
  (CompilerLiveInstrScan CompilerLiveInstrSetList CompilerLiveI64Set))

(define (compiler-live-set-word-bits) : i64
  31)

(define (compiler-live-set-bits-mask) : i64
  (- (shl 1 (compiler-live-set-word-bits)) 1))

(define (compiler-live-set-word-index [value : i64]) : i64
  (/ value (compiler-live-set-word-bits)))

(define (compiler-live-set-bit-index [value : i64]) : i64
  (% value (compiler-live-set-word-bits)))

(define (compiler-live-set-bit-mask [value : i64]) : i64
  (shl 1 (compiler-live-set-bit-index value)))

(define (compiler-live-set-pack-word [word-index : i64] [bits : i64]) : i64
  (bit-or (shl word-index (compiler-live-set-word-bits)) bits))

(define (compiler-live-set-chunk-word-index [chunk : i64]) : i64
  (shr chunk (compiler-live-set-word-bits)))

(define (compiler-live-set-chunk-bits [chunk : i64]) : i64
  (bit-and chunk (compiler-live-set-bits-mask)))

(define (compiler-live-set-empty) : CompilerLiveI64Set
  CompilerLiveI64Nil)

(define (compiler-live-set-contains-word?
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [mask : i64]) : bool
  (match set
    [(CompilerLiveI64Nil) false]
    [(CompilerLiveI64Cons chunk rest)
      (let
        [head-index : i64 (compiler-live-set-chunk-word-index chunk)]
        [bits : i64 (compiler-live-set-chunk-bits chunk)]
        (if (= head-index word-index)
          (not (= (bit-and bits mask) 0))
          (if (> head-index word-index)
            false
            (compiler-live-set-contains-word? rest word-index mask))))]))

(define (compiler-live-set-contains? [set : CompilerLiveI64Set] [value : i64]) : bool
  (if (< value 0)
    false
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      (compiler-live-set-contains-word? set word-index mask))))

(define (compiler-live-set-insert-word
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [mask : i64]) : CompilerLiveI64Set
  (match set
    [(CompilerLiveI64Nil)
      (CompilerLiveI64Cons
        (compiler-live-set-pack-word word-index mask)
        CompilerLiveI64Nil)]
    [(CompilerLiveI64Cons chunk rest)
      (let
        [head-index : i64 (compiler-live-set-chunk-word-index chunk)]
        [bits : i64 (compiler-live-set-chunk-bits chunk)]
        (if (= head-index word-index)
          (if (= (bit-and bits mask) 0)
            (CompilerLiveI64Cons
              (compiler-live-set-pack-word head-index (bit-or bits mask))
              rest)
            set)
          (if (> head-index word-index)
            (CompilerLiveI64Cons
              (compiler-live-set-pack-word word-index mask)
              set)
            (CompilerLiveI64Cons
              chunk
              (compiler-live-set-insert-word rest word-index mask)))))]))

(define (compiler-live-set-insert [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      (compiler-live-set-insert-word set word-index mask))))

(define (compiler-live-set-remove-word
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [mask : i64]) : CompilerLiveI64Set
  (match set
    [(CompilerLiveI64Nil) CompilerLiveI64Nil]
    [(CompilerLiveI64Cons chunk rest)
      (let
        [head-index : i64 (compiler-live-set-chunk-word-index chunk)]
        [bits : i64 (compiler-live-set-chunk-bits chunk)]
        (if (= head-index word-index)
          (let
            [next-bits : i64 (bit-and bits (bit-xor mask -1))]
            (if (= next-bits 0)
              rest
              (if (= next-bits bits)
                set
                (CompilerLiveI64Cons
                  (compiler-live-set-pack-word head-index next-bits)
                  rest))))
          (if (> head-index word-index)
            set
            (CompilerLiveI64Cons
              chunk
              (compiler-live-set-remove-word rest word-index mask)))))]))

(define (compiler-live-set-remove [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      (compiler-live-set-remove-word set word-index mask))))

(define (compiler-live-set-union
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match left
    [(CompilerLiveI64Nil) right]
    [(CompilerLiveI64Cons left-chunk left-rest)
      (let
        [left-index : i64 (compiler-live-set-chunk-word-index left-chunk)]
        [left-bits : i64 (compiler-live-set-chunk-bits left-chunk)]
        (match right
          [(CompilerLiveI64Nil) left]
          [(CompilerLiveI64Cons right-chunk right-rest)
            (let
              [right-index : i64
                (compiler-live-set-chunk-word-index right-chunk)]
              [right-bits : i64 (compiler-live-set-chunk-bits right-chunk)]
              (if (= left-index right-index)
                (CompilerLiveI64Cons
                  (compiler-live-set-pack-word
                    left-index
                    (bit-or left-bits right-bits))
                  (compiler-live-set-union left-rest right-rest))
                (if (< left-index right-index)
                  (CompilerLiveI64Cons
                    left-chunk
                    (compiler-live-set-union left-rest right))
                  (CompilerLiveI64Cons
                    right-chunk
                    (compiler-live-set-union left right-rest)))))]))]))

(define (compiler-live-set-union-into
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (compiler-live-set-union left right))

(define (compiler-live-set-minus
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match left
    [(CompilerLiveI64Nil) CompilerLiveI64Nil]
    [(CompilerLiveI64Cons left-chunk left-rest)
      (let
        [left-index : i64 (compiler-live-set-chunk-word-index left-chunk)]
        [left-bits : i64 (compiler-live-set-chunk-bits left-chunk)]
        (match right
          [(CompilerLiveI64Nil) left]
          [(CompilerLiveI64Cons right-chunk right-rest)
            (let
              [right-index : i64
                (compiler-live-set-chunk-word-index right-chunk)]
              [right-bits : i64 (compiler-live-set-chunk-bits right-chunk)]
              (if (= left-index right-index)
                (let
                  [next-bits : i64 (bit-and left-bits (bit-xor right-bits -1))]
                  (if (= next-bits 0)
                    (compiler-live-set-minus left-rest right-rest)
                    (CompilerLiveI64Cons
                      (compiler-live-set-pack-word left-index next-bits)
                      (compiler-live-set-minus left-rest right-rest))))
                (if (< left-index right-index)
                  (CompilerLiveI64Cons
                    left-chunk
                    (compiler-live-set-minus left-rest right))
                  (compiler-live-set-minus left right-rest))))]))]))

(define (compiler-live-set-eq?
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : bool
  (match left
    [(CompilerLiveI64Nil)
      (match right
        [(CompilerLiveI64Nil) true]
        [(CompilerLiveI64Cons _ _) false])]
    [(CompilerLiveI64Cons left-chunk left-rest)
      (match right
        [(CompilerLiveI64Nil) false]
        [(CompilerLiveI64Cons right-chunk right-rest)
          (and
            (= left-chunk right-chunk)
            (compiler-live-set-eq? left-rest right-rest))])]))

(define (compiler-live-set-word-count-bits [bits : i64] [bit : i64]) : i64
  (if (>= bit (compiler-live-set-word-bits))
    0
    (+
      (if (= (bit-and bits (shl 1 bit)) 0)
        0
        1)
      (compiler-live-set-word-count-bits bits (+ bit 1)))))

(define (compiler-live-set-count [set : CompilerLiveI64Set]) : i64
  (match set
    [(CompilerLiveI64Nil) 0]
    [(CompilerLiveI64Cons chunk rest)
      (+
        (compiler-live-set-word-count-bits
          (compiler-live-set-chunk-bits chunk)
          0)
        (compiler-live-set-count rest))]))

(define (compiler-live-set-score-word-desc
  [bits : i64]
  [base : i64]
  [bit : i64]
  [acc : i64]) : i64
  (if (< bit 0)
    acc
    (compiler-live-set-score-word-desc
      bits
      base
      (- bit 1)
      (if (= (bit-and bits (shl 1 bit)) 0)
        acc
        (+ (+ base (+ bit 1)) (* 17 acc))))))

(define (compiler-live-set-score [set : CompilerLiveI64Set]) : i64
  (match set
    [(CompilerLiveI64Nil) 0]
    [(CompilerLiveI64Cons chunk rest)
      (compiler-live-set-score-word-desc
        (compiler-live-set-chunk-bits chunk)
        (*
          (compiler-live-set-chunk-word-index chunk)
          (compiler-live-set-word-bits))
        (- (compiler-live-set-word-bits) 1)
        (compiler-live-set-score rest))]))

(define (compiler-live-set1 [a : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert (compiler-live-set-empty) a))

(define (compiler-live-set2 [a : i64] [b : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert (compiler-live-set-empty) a)
    b))

(define (compiler-live-set3 [a : i64] [b : i64] [c : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert (compiler-live-set-empty) a)
      b)
    c))

(define (compiler-live-set5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert
        (compiler-live-set-insert
          (compiler-live-set-insert (compiler-live-set-empty) a)
          b)
        c)
      d)
    e))

(define (compiler-live-set6
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert
        (compiler-live-set-insert
          (compiler-live-set-insert
            (compiler-live-set-insert (compiler-live-set-empty) a)
            b)
          c)
        d)
      e)
    f))

(define (compiler-live-set7
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert
        (compiler-live-set-insert
          (compiler-live-set-insert
            (compiler-live-set-insert
              (compiler-live-set-insert (compiler-live-set-empty) a)
              b)
            c)
          d)
        e)
      f)
    g))

(define (compiler-live-label-set-empty) : CompilerLiveLabelSet
  CompilerLiveLabelNil)

(define (compiler-live-label-set-contains?
  [set : CompilerLiveLabelSet]
  [value : String]) : bool
  (match set
    [(CompilerLiveLabelNil) false]
    [(CompilerLiveLabelCons head rest)
      (if (string-eq head value)
        true
        (compiler-live-label-set-contains? rest value))]))

(define (compiler-live-label-set-insert
  [set : CompilerLiveLabelSet]
  [value : String]) : CompilerLiveLabelSet
  (if (compiler-live-label-set-contains? set value)
    set
    (CompilerLiveLabelCons value set)))

(define (compiler-live-label-set-count [set : CompilerLiveLabelSet]) : i64
  (match set
    [(CompilerLiveLabelNil) 0]
    [(CompilerLiveLabelCons _ rest) (+ 1 (compiler-live-label-set-count rest))]))

(define (compiler-live-value-vars [value : CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(IrValueVar id) (compiler-live-set1 id)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-value-list-vars [values : CompilerIrValueList]) : CompilerLiveI64Set
  (match values
    [(IrValueNil) (compiler-live-set-empty)]
    [(IrValueCons value rest)
      (compiler-live-set-union
        (compiler-live-value-vars value)
        (compiler-live-value-list-vars rest))]))

(define (compiler-live-call-args-array-vars
  [values : (Array CompilerIrValue)]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (array-length values))
    (compiler-live-set-empty)
    (compiler-live-set-union
      (compiler-live-value-vars (array-ref values index))
      (compiler-live-call-args-array-vars values (+ index 1)))))

(define (compiler-live-call-args-vars [args : CompilerIrCallArgs]) : CompilerLiveI64Set
  (match args
    [(IrCallArgsNil) (compiler-live-set-empty)]
    [(IrCallArgsOne value) (compiler-live-value-vars value)]
    [(IrCallArgsTwo a b)
      (compiler-live-set-union
        (compiler-live-value-vars a)
        (compiler-live-value-vars b))]
    [(IrCallArgsArray values) (compiler-live-call-args-array-vars values 0)]))

(define (compiler-live-maybe-value-vars [value : CompilerIrMaybeValue]) : CompilerLiveI64Set
  (match value
    [(IrNoValue) (compiler-live-set-empty)]
    [(IrSomeValue inner) (compiler-live-value-vars inner)]))

(define (compiler-live-phi-input-vars [inputs : CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match inputs
    [(IrPhiInputNil) (compiler-live-set-empty)]
    [(IrPhiInputCons value _ rest)
      (compiler-live-set-union
        (compiler-live-value-vars value)
        (compiler-live-phi-input-vars rest))]))

(define (compiler-live-instr-uses [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov _ src _) (compiler-live-value-vars src)]
    [(IrInstrAlloc _ _) (compiler-live-set-empty)]
    [(IrInstrAddrOf _ src) (compiler-live-set1 src)]
    [(IrInstrGep _ base offset _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-value-vars offset))]
    [(IrInstrLoad _ src _) (compiler-live-value-vars src)]
    [(IrInstrStorePtr dst src _)
      (compiler-live-set-union
        (compiler-live-value-vars dst)
        (compiler-live-value-vars src))]
    [(IrInstrBoundsCheck index length _)
      (compiler-live-set-union
        (compiler-live-value-vars index)
        (compiler-live-value-vars length))]
    [(IrInstrCast _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-live-set-union
        (compiler-live-value-vars lhs)
        (compiler-live-value-vars rhs))]
    [(IrInstrUnOp _ _ src _) (compiler-live-value-vars src)]
    [(IrInstrLaneId _ _ _) (compiler-live-set-empty)]
    [(IrInstrSplat _ value _ _) (compiler-live-value-vars value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-live-set-union
        (compiler-live-value-vars lhs)
        (compiler-live-value-vars rhs))]
    [(IrInstrVectorReduce _ _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-live-set-union
        (compiler-live-value-vars lhs)
        (compiler-live-value-vars rhs))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-live-set-union
        (compiler-live-value-vars lhs)
        (compiler-live-value-vars rhs))]
    [(IrInstrMaskNot _ src _) (compiler-live-value-vars src)]
    [(IrInstrMaskReduce _ _ src _) (compiler-live-value-vars src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-live-set-union
        (compiler-live-value-vars mask)
        (compiler-live-set-union
          (compiler-live-value-vars on-true)
          (compiler-live-value-vars on-false)))]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-value-vars index))]
    [(IrInstrVectorStore base index value _ _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-set-union
          (compiler-live-value-vars index)
          (compiler-live-value-vars value)))]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-set-union
          (compiler-live-value-vars index)
          (compiler-live-set-union
            (compiler-live-value-vars value)
            (compiler-live-value-vars mask))))]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-set-union
          (compiler-live-value-vars index)
          (compiler-live-value-vars mask)))]
    [(IrInstrTailMask _ index len _)
      (compiler-live-set-union
        (compiler-live-value-vars index)
        (compiler-live-value-vars len))]
    [(IrInstrEntryArgc _) (compiler-live-set-empty)]
    [(IrInstrEntryArgv _) (compiler-live-set-empty)]
    [(IrInstrEntryEnvp _) (compiler-live-set-empty)]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-live-set-union
        (compiler-live-value-vars leaf)
        (compiler-live-value-vars subleaf))]
    [(IrInstrXgetbv _ index) (compiler-live-value-vars index)]
    [(IrInstrCall _ _ args _) (compiler-live-call-args-vars args)]
    [(IrInstrCallIndirect _ func args _)
      (compiler-live-set-union
        (compiler-live-value-vars func)
        (compiler-live-call-args-vars args))]
    [(IrInstrTailCall _ args _) (compiler-live-call-args-vars args)]
    [(IrInstrStore _ value _) (compiler-live-value-vars value)]
    [(IrInstrBranch cond _ _) (compiler-live-value-vars cond)]
    [(IrInstrReturn value) (compiler-live-maybe-value-vars value)]
    [(IrInstrPhi _ inputs _) (compiler-live-phi-input-vars inputs)]
    [(IrInstrJump _) (compiler-live-set-empty)]))

(define (compiler-live-instr-defs [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov dst _ _) (compiler-live-set1 dst)]
    [(IrInstrAlloc dst _) (compiler-live-set1 dst)]
    [(IrInstrAddrOf dst _) (compiler-live-set1 dst)]
    [(IrInstrGep dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrLoad dst _ _) (compiler-live-set1 dst)]
    [(IrInstrCast dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrUnOp dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrLaneId dst _ _) (compiler-live-set1 dst)]
    [(IrInstrSplat dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorReduce dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set1 dst)]
    [(IrInstrMaskReduce dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrSelect dst _ _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrTailMask dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrEntryArgc dst) (compiler-live-set1 dst)]
    [(IrInstrEntryArgv dst) (compiler-live-set1 dst)]
    [(IrInstrEntryEnvp dst) (compiler-live-set1 dst)]
    [(IrInstrCpuId dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrXgetbv dst _) (compiler-live-set1 dst)]
    [(IrInstrCall dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrCallIndirect dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrPhi dst _ _) (compiler-live-set1 dst)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-block-use-def-instrs
  [instrs : CompilerIrInstrList]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(IrInstrNil) (CompilerLiveUseDef uses defs)]
    [(IrInstrCons instr rest)
      (let
        [instr-uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
        [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
        (compiler-live-block-use-def-instrs
          rest
          (compiler-live-set-union
            uses
            (compiler-live-set-minus instr-uses defs))
          (compiler-live-set-union defs instr-defs)))]))

(define (compiler-live-block-use-def [instrs : CompilerIrInstrList]) : CompilerLiveUseDef
  (compiler-live-block-use-def-instrs
    instrs
    (compiler-live-set-empty)
    (compiler-live-set-empty)))

(define (compiler-live-instr-list-last [instrs : CompilerIrInstrList]) : CompilerLiveMaybeInstr
  (match instrs
    [(IrInstrNil) CompilerLiveNoInstr]
    [(IrInstrCons instr rest)
      (match rest
        [(IrInstrNil) (CompilerLiveSomeInstr instr)]
        [_ (compiler-live-instr-list-last rest)])]))

(define (compiler-live-block-successors [block : CompilerIrBlock]) : CompilerLiveLabelSet
  (match block
    [(IrBlock _ instrs)
      (match (compiler-live-instr-list-last instrs)
        [(CompilerLiveNoInstr) CompilerLiveLabelNil]
        [(CompilerLiveSomeInstr instr)
          (match instr
            [(IrInstrJump target)
              (CompilerLiveLabelCons target CompilerLiveLabelNil)]
            [(IrInstrBranch _ true-label false-label)
              (compiler-live-label-set-insert
                (CompilerLiveLabelCons true-label CompilerLiveLabelNil)
                false-label)]
            [_ CompilerLiveLabelNil])])]))

(define (compiler-live-build-block [block : CompilerIrBlock]) : CompilerLiveBlock
  (match block
    [(IrBlock label instrs)
      (match (compiler-live-block-use-def instrs)
        [(CompilerLiveUseDef uses defs)
          (CompilerLiveBlock
            label
            uses
            defs
            (compiler-live-set-empty)
            (compiler-live-set-empty)
            (compiler-live-block-successors block)
            CompilerLiveInstrSetNil)])]))

(define (compiler-live-build-blocks [blocks : CompilerIrBlockList]) : CompilerLiveBlockList
  (match blocks
    [(IrBlockNil) CompilerLiveBlockNil]
    [(IrBlockCons block rest)
      (CompilerLiveBlockCons
        (compiler-live-build-block block)
        (compiler-live-build-blocks rest))]))

(define (compiler-live-find-block
  [blocks : CompilerLiveBlockList]
  [label : String]) : CompilerLiveMaybeBlock
  (match blocks
    [(CompilerLiveBlockNil) CompilerLiveNoBlock]
    [(CompilerLiveBlockCons block rest)
      (match block
        [(CompilerLiveBlock block-label _ _ _ _ _ _)
          (if (string-eq block-label label)
            (CompilerLiveSomeBlock block)
            (compiler-live-find-block rest label))])]))

(define (compiler-live-successor-live-out
  [successors : CompilerLiveLabelSet]
  [blocks : CompilerLiveBlockList]) : CompilerLiveI64Set
  (match successors
    [(CompilerLiveLabelNil) (compiler-live-set-empty)]
    [(CompilerLiveLabelCons label rest)
      (let
        [rest-live : CompilerLiveI64Set
          (compiler-live-successor-live-out rest blocks)]
        (match (compiler-live-find-block blocks label)
          [(CompilerLiveSomeBlock block)
            (match block
              [(CompilerLiveBlock _ _ _ live-in _ _ _)
                (compiler-live-set-union live-in rest-live)])]
          [(CompilerLiveNoBlock) rest-live]))]))

(define (compiler-live-recompute-block
  [block : CompilerLiveBlock]
  [blocks : CompilerLiveBlockList]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock label uses defs _ _ successors instr-after)
      (let
        [live-out : CompilerLiveI64Set
          (compiler-live-successor-live-out successors blocks)]
        [live-in : CompilerLiveI64Set
          (compiler-live-set-union uses (compiler-live-set-minus live-out defs))]
        (CompilerLiveBlock
          label
          uses
          defs
          live-in
          live-out
          successors
          instr-after))]))

(define (compiler-live-block-liveness-eq?
  [left : CompilerLiveBlock]
  [right : CompilerLiveBlock]) : bool
  (match left
    [(CompilerLiveBlock _ _ _ left-in left-out _ _)
      (match right
        [(CompilerLiveBlock _ _ _ right-in right-out _ _)
          (and
            (compiler-live-set-eq? left-in right-in)
            (compiler-live-set-eq? left-out right-out))])]))

(define (compiler-live-update-blocks
  [blocks : CompilerLiveBlockList]
  [all-blocks : CompilerLiveBlockList]) : CompilerLiveBlockListStep
  (match blocks
    [(CompilerLiveBlockNil)
      (CompilerLiveBlockListStep CompilerLiveBlockNil false)]
    [(CompilerLiveBlockCons block rest)
      (let
        [updated : CompilerLiveBlock
          (compiler-live-recompute-block block all-blocks)]
        (match (compiler-live-update-blocks rest all-blocks)
          [(CompilerLiveBlockListStep updated-rest rest-changed)
            (CompilerLiveBlockListStep
              (CompilerLiveBlockCons updated updated-rest)
              (if (compiler-live-block-liveness-eq? block updated)
                rest-changed
                true))]))]))

(define (compiler-live-fixpoint [blocks : CompilerLiveBlockList]) : CompilerLiveBlockList
  (let
    [current : CompilerLiveBlockList blocks]
    [done : bool false]
    (begin
      (while (not done)
        (match (compiler-live-update-blocks current current)
          [(CompilerLiveBlockListStep next changed)
            (begin
              (set! current next)
              (set! done (not changed)))]))
      current)))

(define (compiler-live-before-instr
  [live-after : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (compiler-live-set-union
    (compiler-live-instr-uses instr)
    (compiler-live-set-minus live-after (compiler-live-instr-defs instr))))

(define (compiler-live-instr-scan
  [instrs : CompilerIrInstrList]
  [live-out : CompilerLiveI64Set]) : CompilerLiveInstrScan
  (match instrs
    [(IrInstrNil) (CompilerLiveInstrScan CompilerLiveInstrSetNil live-out)]
    [(IrInstrCons instr rest)
      (match (compiler-live-instr-scan rest live-out)
        [(CompilerLiveInstrScan rest-after live-after)
          (CompilerLiveInstrScan
            (CompilerLiveInstrSetCons live-after rest-after)
            (compiler-live-before-instr live-after instr))])]))

(define (compiler-live-fill-instr-after-block
  [ir-blocks : CompilerIrBlockList]
  [block : CompilerLiveBlock]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock label uses defs live-in live-out successors _)
      (match (compiler-live-find-ir-block ir-blocks label)
        [(CompilerLiveSomeIrBlock ir-block)
          (match ir-block
            [(IrBlock _ instrs)
              (match (compiler-live-instr-scan instrs live-out)
                [(CompilerLiveInstrScan instr-after _)
                  (CompilerLiveBlock
                    label
                    uses
                    defs
                    live-in
                    live-out
                    successors
                    instr-after)])])]
        [(CompilerLiveNoIrBlock)
          (CompilerLiveBlock
            label
            uses
            defs
            live-in
            live-out
            successors
            CompilerLiveInstrSetNil)])]))

(define (compiler-live-find-ir-block
  [blocks : CompilerIrBlockList]
  [label : String]) : CompilerLiveMaybeIrBlock
  (match blocks
    [(IrBlockNil) CompilerLiveNoIrBlock]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (if (string-eq block-label label)
            (CompilerLiveSomeIrBlock block)
            (compiler-live-find-ir-block rest label))])]))

(define (compiler-live-fill-instr-after-blocks
  [ir-blocks : CompilerIrBlockList]
  [blocks : CompilerLiveBlockList]) : CompilerLiveBlockList
  (match blocks
    [(CompilerLiveBlockNil) CompilerLiveBlockNil]
    [(CompilerLiveBlockCons block rest)
      (CompilerLiveBlockCons
        (compiler-live-fill-instr-after-block ir-blocks block)
        (compiler-live-fill-instr-after-blocks ir-blocks rest))]))

(define (compiler-live-analyze-function [func : CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(IrFunction _ _ _ _ blocks)
      (let
        [fixed : CompilerLiveBlockList
          (compiler-live-fixpoint (compiler-live-build-blocks blocks))]
        (CompilerFunctionLiveness
          (compiler-live-fill-instr-after-blocks blocks fixed)))]))

(define (compiler-live-function-blocks [liveness : CompilerFunctionLiveness]) : CompilerLiveBlockList
  (match liveness
    [(CompilerFunctionLiveness blocks) blocks]))

(define (compiler-live-block-label [block : CompilerLiveBlock]) : String
  (match block
    [(CompilerLiveBlock label _ _ _ _ _ _) label]))

(define (compiler-live-block-uses [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock _ uses _ _ _ _ _) uses]))

(define (compiler-live-block-defs [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock _ _ defs _ _ _ _) defs]))

(define (compiler-live-block-live-in [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock _ _ _ live-in _ _ _) live-in]))

(define (compiler-live-block-live-out [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock _ _ _ _ live-out _ _) live-out]))

(define (compiler-live-block-successor-labels [block : CompilerLiveBlock]) : CompilerLiveLabelSet
  (match block
    [(CompilerLiveBlock _ _ _ _ _ successors _) successors]))

(define (compiler-live-block-instr-after [block : CompilerLiveBlock]) : CompilerLiveInstrSetList
  (match block
    [(CompilerLiveBlock _ _ _ _ _ _ instr-after) instr-after]))

(define (compiler-live-instr-set-list-nth
  [sets : CompilerLiveInstrSetList]
  [index : i64]) : CompilerLiveI64Set
  (match sets
    [(CompilerLiveInstrSetNil) (compiler-live-set-empty)]
    [(CompilerLiveInstrSetCons head rest)
      (if (= index 0)
        head
        (compiler-live-instr-set-list-nth rest (- index 1)))]))

(define (compiler-live-after
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [index : i64]) : CompilerLiveI64Set
  (match (compiler-live-find-block
    (compiler-live-function-blocks liveness)
    label)
    [(CompilerLiveSomeBlock block)
      (compiler-live-instr-set-list-nth
        (compiler-live-block-instr-after block)
        index)]
    [(CompilerLiveNoBlock) (compiler-live-set-empty)]))

(define (compiler-live-i64-ty) : AstType
  (AstTyI64))

(define (compiler-live-straight-function) : CompilerIrFunction
  (IrFunction
    "straight"
    IrParamNil
    (compiler-live-i64-ty)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 1) (compiler-live-i64-ty))
          (IrInstrCons
            (IrInstrBinOp
              1
              IrBinAdd
              (IrValueVar 0)
              (IrValueVar 2)
              (compiler-live-i64-ty))
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              IrInstrNil))))
      IrBlockNil)))

(define (compiler-live-branch-function) : CompilerIrFunction
  (IrFunction
    "branch"
    IrParamNil
    (compiler-live-i64-ty)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrBranch (IrValueVar 0) "then" "else") IrInstrNil))
      (IrBlockCons
        (IrBlock
          "then"
          (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 1))) IrInstrNil))
        (IrBlockCons
          (IrBlock
            "else"
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueVar 2)))
              IrInstrNil))
          IrBlockNil)))))

(define (compiler-live-phi-function) : CompilerIrFunction
  (IrFunction
    "phi"
    IrParamNil
    (compiler-live-i64-ty)
    4
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrBranch (IrValueVar 0) "left" "right") IrInstrNil))
      (IrBlockCons
        (IrBlock
          "left"
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 10) (compiler-live-i64-ty))
            (IrInstrCons (IrInstrJump "join") IrInstrNil)))
        (IrBlockCons
          (IrBlock
            "right"
            (IrInstrCons
              (IrInstrMov 2 (IrValueI64 20) (compiler-live-i64-ty))
              (IrInstrCons (IrInstrJump "join") IrInstrNil)))
          (IrBlockCons
            (IrBlock
              "join"
              (IrInstrCons
                (IrInstrPhi
                  3
                  (IrPhiInputCons
                    (IrValueVar 1)
                    "left"
                    (IrPhiInputCons (IrValueVar 2) "right" IrPhiInputNil))
                  (compiler-live-i64-ty))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  IrInstrNil)))
            IrBlockNil))))))

(define (compiler-live-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (IrInstrCons
      (IrInstrMov 0 (IrValueVar 10) (compiler-live-i64-ty))
      (IrInstrCons
        (IrInstrBinOp
          1
          IrBinAdd
          (IrValueVar 0)
          (IrValueVar 11)
          (compiler-live-i64-ty))
        (IrInstrCons
          (IrInstrUnOp 2 IrUnNeg (IrValueVar 12) (compiler-live-i64-ty))
          (IrInstrCons
            (IrInstrCall
              3
              "f"
              (IrCallArgsTwo (IrValueVar 1) (IrValueVar 13))
              (compiler-live-i64-ty))
            (IrInstrCons
              (IrInstrStore "g" (IrValueVar 14) (compiler-live-i64-ty))
              (IrInstrCons
                (IrInstrBranch (IrValueVar 15) "a" "b")
                (IrInstrCons
                  (IrInstrPhi
                    4
                    (IrPhiInputCons (IrValueVar 16) "a" IrPhiInputNil)
                    (compiler-live-i64-ty))
                  (IrInstrCons
                    (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                    IrInstrNil)))))))))
    [(CompilerLiveUseDef uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set7 10 11 12 13 14 15 16))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-memory-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (IrInstrCons
      (IrInstrAlloc 0 (compiler-live-i64-ty))
      (IrInstrCons
        (IrInstrAddrOf 1 0)
        (IrInstrCons
          (IrInstrGep 2 (IrValueVar 1) (IrValueVar 10) (compiler-live-i64-ty))
          (IrInstrCons
            (IrInstrLoad 3 (IrValueVar 2) (compiler-live-i64-ty))
            (IrInstrCons
              (IrInstrStorePtr
                (IrValueVar 2)
                (IrValueVar 11)
                (compiler-live-i64-ty))
              (IrInstrCons
                (IrInstrCast 4 (IrValueVar 3) (compiler-live-i64-ty) (AstTyI32))
                IrInstrNil)))))))
    [(CompilerLiveUseDef uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set2 10 11))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (IrInstrCons
      (IrInstrLaneId 0 4 (compiler-live-i64-ty))
      (IrInstrCons
        (IrInstrSplat 1 (IrValueVar 10) 4 (compiler-live-i64-ty))
        (IrInstrCons
          (IrInstrVectorBinOp
            2
            (IrBinAdd)
            (IrValueVar 0)
            (IrValueVar 1)
            4
            (compiler-live-i64-ty))
          (IrInstrCons
            (IrInstrTailMask 3 (IrValueVar 11) (IrValueVar 12) 4)
            (IrInstrCons
              (IrInstrPredicatedLoad
                4
                (IrValueVar 13)
                (IrValueVar 11)
                (IrValueVar 3)
                4
                (compiler-live-i64-ty))
              (IrInstrCons
                (IrInstrPredicatedStore
                  (IrValueVar 14)
                  (IrValueVar 11)
                  (IrValueVar 2)
                  (IrValueVar 3)
                  4
                  (compiler-live-i64-ty))
                (IrInstrCons
                  (IrInstrMaskReduce 5 (IrMaskReduceAny) (IrValueVar 3) 4)
                  IrInstrNil))))))))
    [(CompilerLiveUseDef uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set5 10 11 12 13 14))
        (compiler-live-set-eq? defs (compiler-live-set6 0 1 2 3 4 5)))]))

(define (compiler-live-straight-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-straight-function))]
    (match (compiler-live-find-block
      (compiler-live-function-blocks liveness)
      "entry")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (compiler-live-set1 2))
          (and
            (compiler-live-set-eq?
              (compiler-live-block-defs block)
              (compiler-live-set2 0 1))
            (and
              (compiler-live-set-eq?
                (compiler-live-block-live-in block)
                (compiler-live-set1 2))
              (and
                (compiler-live-set-eq?
                  (compiler-live-block-live-out block)
                  (compiler-live-set-empty))
                (and
                  (compiler-live-set-eq?
                    (compiler-live-after liveness "entry" 0)
                    (compiler-live-set2 0 2))
                  (and
                    (compiler-live-set-eq?
                      (compiler-live-after liveness "entry" 1)
                      (compiler-live-set1 1))
                    (compiler-live-set-eq?
                      (compiler-live-after liveness "entry" 2)
                      (compiler-live-set-empty))))))))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))]
    (match (compiler-live-find-block
      (compiler-live-function-blocks liveness)
      "entry")
      [(CompilerLiveSomeBlock block)
        (and
          (=
            (compiler-live-label-set-count
              (compiler-live-block-successor-labels block))
            2)
          (and
            (compiler-live-label-set-contains?
              (compiler-live-block-successor-labels block)
              "then")
            (and
              (compiler-live-label-set-contains?
                (compiler-live-block-successor-labels block)
                "else")
              (compiler-live-set-eq?
                (compiler-live-block-live-in block)
                (compiler-live-set3 0 1 2)))))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))]
    (match (compiler-live-find-block
      (compiler-live-function-blocks liveness)
      "join")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (compiler-live-set2 1 2))
          (and
            (compiler-live-set-eq?
              (compiler-live-block-defs block)
              (compiler-live-set1 3))
            (and
              (compiler-live-set-eq?
                (compiler-live-block-live-in block)
                (compiler-live-set2 1 2))
              (and
                (compiler-live-set-eq?
                  (compiler-live-after liveness "join" 0)
                  (compiler-live-set1 3))
                (match (compiler-live-find-block
                  (compiler-live-function-blocks liveness)
                  "left")
                  [(CompilerLiveSomeBlock left-block)
                    (compiler-live-label-set-contains?
                      (compiler-live-block-successor-labels left-block)
                      "join")]
                  [(CompilerLiveNoBlock) false])))))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-use-def-ok?)
    (and
      (compiler-live-memory-use-def-ok?)
      (and
        (compiler-live-vector-mask-use-def-ok?)
        (and
          (compiler-live-straight-ok?)
          (and (compiler-live-branch-ok?) (compiler-live-phi-ok?))))))
    42
    (begin
      (panic "liveness: smoke mismatch")
      0)))