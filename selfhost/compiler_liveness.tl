;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis (#553).

;;

;; This module keeps the first selfhost liveness pass list-backed and

;; deterministic. It mirrors the current Rust backend liveness shape closely

;; enough for a later register-allocation planner to query block live-in,

;; live-out, and instruction live-after sets.

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

(define (compiler-live-set-empty) : CompilerLiveI64Set
  CompilerLiveI64Nil)

(define (compiler-live-set-contains? [set : CompilerLiveI64Set] [value : i64]) : bool
  (match set
    [(CompilerLiveI64Nil) false]
    [(CompilerLiveI64Cons head rest)
      (if (= head value)
        true
        (if (> head value)
          false
          (compiler-live-set-contains? rest value)))]))

(define (compiler-live-set-insert [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (match set
    [(CompilerLiveI64Nil) (CompilerLiveI64Cons value CompilerLiveI64Nil)]
    [(CompilerLiveI64Cons head rest)
      (if (= head value)
        set
        (if (> head value)
          (CompilerLiveI64Cons value set)
          (CompilerLiveI64Cons head (compiler-live-set-insert rest value))))]))

(define (compiler-live-set-union
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match left
    [(CompilerLiveI64Nil) right]
    [(CompilerLiveI64Cons head rest)
      (compiler-live-set-union rest (compiler-live-set-insert right head))]))

(define (compiler-live-set-remove [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (match set
    [(CompilerLiveI64Nil) CompilerLiveI64Nil]
    [(CompilerLiveI64Cons head rest)
      (if (= head value)
        rest
        (if (> head value)
          set
          (CompilerLiveI64Cons head (compiler-live-set-remove rest value))))]))

(define (compiler-live-set-minus
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match right
    [(CompilerLiveI64Nil) left]
    [(CompilerLiveI64Cons head rest)
      (compiler-live-set-minus (compiler-live-set-remove left head) rest)]))

(define (compiler-live-set-eq?
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : bool
  (match left
    [(CompilerLiveI64Nil)
      (match right
        [(CompilerLiveI64Nil) true]
        [_ false])]
    [(CompilerLiveI64Cons left-head left-rest)
      (match right
        [(CompilerLiveI64Cons right-head right-rest)
          (and
            (= left-head right-head)
            (compiler-live-set-eq? left-rest right-rest))]
        [_ false])]))

(define (compiler-live-set-count [set : CompilerLiveI64Set]) : i64
  (match set
    [(CompilerLiveI64Nil) 0]
    [(CompilerLiveI64Cons _ rest) (+ 1 (compiler-live-set-count rest))]))

(define (compiler-live-set-score [set : CompilerLiveI64Set]) : i64
  (match set
    [(CompilerLiveI64Nil) 0]
    [(CompilerLiveI64Cons head rest)
      (+ (+ head 1) (* 17 (compiler-live-set-score rest)))]))

(define (compiler-live-set2 [a : i64] [b : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert (compiler-live-set-insert CompilerLiveI64Nil a) b))

(define (compiler-live-set3 [a : i64] [b : i64] [c : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert (compiler-live-set-insert CompilerLiveI64Nil a) b)
    c))

(define (compiler-live-set5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert
        (compiler-live-set-insert
          (compiler-live-set-insert CompilerLiveI64Nil a)
          b)
        c)
      d)
    e))

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
              (compiler-live-set-insert CompilerLiveI64Nil a)
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
    [(IrValueVar id) (CompilerLiveI64Cons id CompilerLiveI64Nil)]
    [_ CompilerLiveI64Nil]))

(define (compiler-live-value-list-vars [values : CompilerIrValueList]) : CompilerLiveI64Set
  (match values
    [(IrValueNil) CompilerLiveI64Nil]
    [(IrValueCons value rest)
      (compiler-live-set-union
        (compiler-live-value-vars value)
        (compiler-live-value-list-vars rest))]))

(define (compiler-live-maybe-value-vars [value : CompilerIrMaybeValue]) : CompilerLiveI64Set
  (match value
    [(IrNoValue) CompilerLiveI64Nil]
    [(IrSomeValue inner) (compiler-live-value-vars inner)]))

(define (compiler-live-phi-input-vars [inputs : CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match inputs
    [(IrPhiInputNil) CompilerLiveI64Nil]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (compiler-live-set-union
            (compiler-live-value-vars value)
            (compiler-live-phi-input-vars rest))])]))

(define (compiler-live-instr-uses [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov _ src _) (compiler-live-value-vars src)]
    [(IrInstrAlloc _ _) CompilerLiveI64Nil]
    [(IrInstrAddrOf _ src) (CompilerLiveI64Cons src CompilerLiveI64Nil)]
    [(IrInstrGep _ base offset _)
      (compiler-live-set-union
        (compiler-live-value-vars base)
        (compiler-live-value-vars offset))]
    [(IrInstrLoad _ src _) (compiler-live-value-vars src)]
    [(IrInstrStorePtr dst src _)
      (compiler-live-set-union
        (compiler-live-value-vars dst)
        (compiler-live-value-vars src))]
    [(IrInstrCast _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-live-set-union
        (compiler-live-value-vars lhs)
        (compiler-live-value-vars rhs))]
    [(IrInstrUnOp _ _ src _) (compiler-live-value-vars src)]
    [(IrInstrCall _ _ args _) (compiler-live-value-list-vars args)]
    [(IrInstrStore _ value _) (compiler-live-value-vars value)]
    [(IrInstrBranch cond _ _) (compiler-live-value-vars cond)]
    [(IrInstrReturn value) (compiler-live-maybe-value-vars value)]
    [(IrInstrPhi _ inputs _) (compiler-live-phi-input-vars inputs)]
    [(IrInstrJump _) CompilerLiveI64Nil]))

(define (compiler-live-instr-defs [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov dst _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrAlloc dst _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrAddrOf dst _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrGep dst _ _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrLoad dst _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrCast dst _ _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrBinOp dst _ _ _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrUnOp dst _ _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrCall dst _ _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [(IrInstrPhi dst _ _) (CompilerLiveI64Cons dst CompilerLiveI64Nil)]
    [_ CompilerLiveI64Nil]))

(define (compiler-live-block-use-def-instrs
  [instrs : CompilerIrInstrList]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(IrInstrNil) (CompilerLiveUseDef uses defs)]
    [(IrInstrCons instr rest)
      (let ([instr-uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
        [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)])
        (compiler-live-block-use-def-instrs
          rest
          (compiler-live-set-union
            uses
            (compiler-live-set-minus instr-uses defs))
          (compiler-live-set-union defs instr-defs)))]))

(define (compiler-live-block-use-def [instrs : CompilerIrInstrList]) : CompilerLiveUseDef
  (compiler-live-block-use-def-instrs
    instrs
    CompilerLiveI64Nil
    CompilerLiveI64Nil))

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
            CompilerLiveI64Nil
            CompilerLiveI64Nil
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
    [(CompilerLiveLabelNil) CompilerLiveI64Nil]
    [(CompilerLiveLabelCons label rest)
      (let ([rest-live
          :
          CompilerLiveI64Set
          (compiler-live-successor-live-out rest blocks)])
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
      (let ([live-out
          :
          CompilerLiveI64Set
          (compiler-live-successor-live-out successors blocks)])
        (let ([live-in
            :
            CompilerLiveI64Set
            (compiler-live-set-union
              uses
              (compiler-live-set-minus live-out defs))])
          (CompilerLiveBlock
            label
            uses
            defs
            live-in
            live-out
            successors
            instr-after)))]))

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
      (let ([updated
          :
          CompilerLiveBlock
          (compiler-live-recompute-block block all-blocks)])
        (match (compiler-live-update-blocks rest all-blocks)
          [(CompilerLiveBlockListStep updated-rest rest-changed)
            (CompilerLiveBlockListStep
              (CompilerLiveBlockCons updated updated-rest)
              (if (compiler-live-block-liveness-eq? block updated)
                rest-changed
                true))]))]))

(define (compiler-live-fixpoint [blocks : CompilerLiveBlockList]) : CompilerLiveBlockList
  (let ([current : CompilerLiveBlockList blocks] [done : bool false])
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
      (let ([fixed
          :
          CompilerLiveBlockList
          (compiler-live-fixpoint (compiler-live-build-blocks blocks))])
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
    [(CompilerLiveInstrSetNil) CompilerLiveI64Nil]
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
    [(CompilerLiveNoBlock) CompilerLiveI64Nil]))

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
                    (IrPhiInput (IrValueVar 1) "left")
                    (IrPhiInputCons
                      (IrPhiInput (IrValueVar 2) "right")
                      IrPhiInputNil))
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
              (IrValueCons
                (IrValueVar 1)
                (IrValueCons (IrValueVar 13) IrValueNil))
              (compiler-live-i64-ty))
            (IrInstrCons
              (IrInstrStore "g" (IrValueVar 14) (compiler-live-i64-ty))
              (IrInstrCons
                (IrInstrBranch (IrValueVar 15) "a" "b")
                (IrInstrCons
                  (IrInstrPhi
                    4
                    (IrPhiInputCons
                      (IrPhiInput (IrValueVar 16) "a")
                      IrPhiInputNil)
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

(define (compiler-live-straight-ok?) : bool
  (let ([liveness
      :
      CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-straight-function))])
    (match (compiler-live-find-block
      (compiler-live-function-blocks liveness)
      "entry")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (CompilerLiveI64Cons 2 CompilerLiveI64Nil))
          (and
            (compiler-live-set-eq?
              (compiler-live-block-defs block)
              (CompilerLiveI64Cons 0 (CompilerLiveI64Cons 1 CompilerLiveI64Nil)))
            (and
              (compiler-live-set-eq?
                (compiler-live-block-live-in block)
                (CompilerLiveI64Cons 2 CompilerLiveI64Nil))
              (and
                (compiler-live-set-eq?
                  (compiler-live-block-live-out block)
                  CompilerLiveI64Nil)
                (and
                  (compiler-live-set-eq?
                    (compiler-live-after liveness "entry" 0)
                    (compiler-live-set2 0 2))
                  (and
                    (compiler-live-set-eq?
                      (compiler-live-after liveness "entry" 1)
                      (CompilerLiveI64Cons 1 CompilerLiveI64Nil))
                    (compiler-live-set-eq?
                      (compiler-live-after liveness "entry" 2)
                      CompilerLiveI64Nil)))))))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-branch-ok?) : bool
  (let ([liveness
      :
      CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))])
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
  (let ([liveness
      :
      CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))])
    (match (compiler-live-find-block
      (compiler-live-function-blocks liveness)
      "join")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (CompilerLiveI64Cons 1 (CompilerLiveI64Cons 2 CompilerLiveI64Nil)))
          (and
            (compiler-live-set-eq?
              (compiler-live-block-defs block)
              (CompilerLiveI64Cons 3 CompilerLiveI64Nil))
            (and
              (compiler-live-set-eq?
                (compiler-live-block-live-in block)
                (CompilerLiveI64Cons
                  1
                  (CompilerLiveI64Cons 2 CompilerLiveI64Nil)))
              (and
                (compiler-live-set-eq?
                  (compiler-live-after liveness "join" 0)
                  (CompilerLiveI64Cons 3 CompilerLiveI64Nil))
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
        (compiler-live-straight-ok?)
        (and (compiler-live-branch-ok?) (compiler-live-phi-ok?)))))
    42
    (begin
      (panic "liveness: smoke mismatch")
      0)))