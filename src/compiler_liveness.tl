;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis (#553).
;;
;; This module keeps the selfhost liveness pass deterministic while storing
;; integer live sets as compact bitsets keyed by dense IR variable ids.
(import "../stdlib/io.tl")
(import "compiler_ir_types.tl")
(import "../stdlib/hashmap.tl")

(defstruct CompilerLiveI64Set
  (words (Array i64)))

(defenum CompilerLiveLabelSet
  (CompilerLiveLabelNil)
  (CompilerLiveLabelCons String (Box CompilerLiveLabelSet)))

(defstruct CompilerLiveIndexVec
  (items (Array i64)))

(defstruct CompilerLiveInstrSetVec
  (items (Array CompilerLiveI64Set)))

(defenum CompilerLiveBlock
  (CompilerLiveBlock
    String
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveLabelSet
    CompilerLiveInstrSetVec))

(defenum CompilerLiveBlockList
  (CompilerLiveBlockNil)
  (CompilerLiveBlockCons CompilerLiveBlock (Box CompilerLiveBlockList)))

(defstruct CompilerLiveBlockGraph
  (ids StringI64Map)
  (blocks (Array CompilerLiveBlock))
  (successors (Array CompilerLiveIndexVec)))

(defenum CompilerFunctionLiveness
  (CompilerFunctionLiveness StringI64Map (Array CompilerLiveBlock)))

(defenum CompilerLiveMaybeBlock
  (CompilerLiveNoBlock)
  (CompilerLiveSomeBlock CompilerLiveBlock))

(defenum CompilerLiveMaybeInstr
  (CompilerLiveNoInstr)
  (CompilerLiveSomeInstr CompilerIrInstr))

(defenum CompilerLiveUseDef
  (CompilerLiveUseDef CompilerLiveI64Set CompilerLiveI64Set))

(defenum CompilerLiveBlockListStep
  (CompilerLiveBlockListStep CompilerLiveBlockList bool))

(defenum CompilerLiveInstrScan
  (CompilerLiveInstrScan CompilerLiveInstrSetVec CompilerLiveI64Set))

(define (compiler-live-instr-set-vec-empty) : CompilerLiveInstrSetVec
  (CompilerLiveInstrSetVec (make-array CompilerLiveI64Set 0)))

(define (compiler-live-block-cons
  [head : CompilerLiveBlock]
  [rest : CompilerLiveBlockList]) : CompilerLiveBlockList
  (CompilerLiveBlockCons head (box rest)))

(define (compiler-live-set-word-bits) : i64
  63)

(define (compiler-live-set-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (compiler-live-set-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-live-set-word-index [value : i64]) : i64
  (/ value (compiler-live-set-word-bits)))

(define (compiler-live-set-bit-index [value : i64]) : i64
  (% value (compiler-live-set-word-bits)))

(define (compiler-live-set-bit-mask [value : i64]) : i64
  (shl 1 (compiler-live-set-bit-index value)))

(define (compiler-live-set-words [set : CompilerLiveI64Set]) : (Array i64)
  (struct-get set words))

(define (compiler-live-set-empty) : CompilerLiveI64Set
  (CompilerLiveI64Set (make-array i64 0)))

(define (compiler-live-set-word-count [set : CompilerLiveI64Set]) : i64
  (array-length (compiler-live-set-words set)))

(define (compiler-live-set-word-at
  [set : CompilerLiveI64Set]
  [word-index : i64]) : i64
  (if (and (>= word-index 0) (< word-index (compiler-live-set-word-count set)))
    (array-ref (compiler-live-set-words set) word-index)
    0))

(define (compiler-live-set-copy-words-into
  [dst : (Array i64)]
  [src : (Array i64)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (compiler-live-set-copy-words-into dst src (+ index 1) count))))

(define (compiler-live-set-copy-with-capacity
  [set : CompilerLiveI64Set]
  [capacity : i64]) : (Array i64)
  (let
    [words : (Array i64) (compiler-live-set-words set)]
    [old-capacity : i64 (array-length words)]
    [out : (Array i64) (make-array i64 capacity)]
    [copy-count : i64 (compiler-live-set-min old-capacity capacity)]
    (begin
      (compiler-live-set-copy-words-into out words 0 copy-count)
      out)))

(define (compiler-live-set-trim-length [words : (Array i64)] [count : i64]) : i64
  (let
    [i : i64 count]
    (begin
      (while (and (> i 0) (= (array-ref words (- i 1)) 0))
        (set! i (- i 1)))
      i)))

(define (compiler-live-set-from-words-trimmed
  [words : (Array i64)]
  [count : i64]) : CompilerLiveI64Set
  (let
    [n : i64 (compiler-live-set-trim-length words count)]
    (if (<= n 0)
      (compiler-live-set-empty)
      (if (= n (array-length words))
        (CompilerLiveI64Set words)
        (let
          [out : (Array i64) (make-array i64 n)]
          (begin
            (compiler-live-set-copy-words-into out words 0 n)
            (CompilerLiveI64Set out)))))))

(define (compiler-live-set-contains? [set : CompilerLiveI64Set] [value : i64]) : bool
  (if (< value 0)
    false
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      (not (= (bit-and (compiler-live-set-word-at set word-index) mask) 0)))))

(define (compiler-live-set-insert [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      [capacity : i64
        (compiler-live-set-max
          (compiler-live-set-word-count set)
          (+ word-index 1))]
      [old-bits : i64 (compiler-live-set-word-at set word-index)]
      (if (not (= (bit-and old-bits mask) 0))
        set
        (let
          [out : (Array i64)
            (compiler-live-set-copy-with-capacity set capacity)]
          (begin
            (array-set! out word-index (bit-or old-bits mask))
            (CompilerLiveI64Set out)))))))

(define (compiler-live-set-remove [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [capacity : i64 (compiler-live-set-word-count set)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      (if (>= word-index capacity)
        set
        (let
          [old-bits : i64 (compiler-live-set-word-at set word-index)]
          (if (= (bit-and old-bits mask) 0)
            set
            (let
              [out : (Array i64)
                (compiler-live-set-copy-with-capacity set capacity)]
              (begin
                (array-set! out word-index (bit-and old-bits (bit-xor mask -1)))
                (compiler-live-set-from-words-trimmed out capacity)))))))))

(define (compiler-live-set-union-words
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]
  [out : (Array i64)]
  [index : i64]
  [count : i64]
  [changed : bool]) : bool
  (if (>= index count)
    changed
    (let
      [left-bits : i64 (compiler-live-set-word-at left index)]
      [merged : i64 (bit-or left-bits (compiler-live-set-word-at right index))]
      (begin
        (array-set! out index merged)
        (compiler-live-set-union-words
          left
          right
          out
          (+ index 1)
          count
          (or changed (not (= merged left-bits))))))))

(define (compiler-live-set-union
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [count : i64
      (compiler-live-set-max
        (compiler-live-set-word-count left)
        (compiler-live-set-word-count right))]
    [out : (Array i64) (make-array i64 count)]
    [changed : bool
      (compiler-live-set-union-words left right out 0 count false)]
    (if changed
      (compiler-live-set-from-words-trimmed out count)
      left)))

(define (compiler-live-set-union-into
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (compiler-live-set-union left right))

(define (compiler-live-set-minus-words
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]
  [out : (Array i64)]
  [index : i64]
  [count : i64]
  [changed : bool]) : bool
  (if (>= index count)
    changed
    (let
      [left-bits : i64 (compiler-live-set-word-at left index)]
      [next-bits : i64
        (bit-and left-bits (bit-xor (compiler-live-set-word-at right index) -1))]
      (begin
        (array-set! out index next-bits)
        (compiler-live-set-minus-words
          left
          right
          out
          (+ index 1)
          count
          (or changed (not (= next-bits left-bits))))))))

(define (compiler-live-set-minus
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [count : i64 (compiler-live-set-word-count left)]
    [out : (Array i64) (make-array i64 count)]
    [changed : bool
      (compiler-live-set-minus-words left right out 0 count false)]
    (if changed
      (compiler-live-set-from-words-trimmed out count)
      left)))

(define (compiler-live-set-eq?
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : bool
  (let
    [count : i64
      (compiler-live-set-max
        (compiler-live-set-word-count left)
        (compiler-live-set-word-count right))]
    [index : i64 0]
    [same : bool true]
    (begin
      (while (and same (< index count))
        (if (=
          (compiler-live-set-word-at left index)
          (compiler-live-set-word-at right index))
          (set! index (+ index 1))
          (set! same false)))
      same)))

(define (compiler-live-set-word-count-bits [bits : i64] [bit : i64]) : i64
  (if (>= bit (compiler-live-set-word-bits))
    0
    (+
      (if (= (bit-and bits (shl 1 bit)) 0)
        0
        1)
      (compiler-live-set-word-count-bits bits (+ bit 1)))))

(define (compiler-live-set-count [set : CompilerLiveI64Set]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    [word-count : i64 (compiler-live-set-word-count set)]
    (begin
      (while (< index word-count)
        (begin
          (set!
            count
            (+
              count
              (compiler-live-set-word-count-bits
                (compiler-live-set-word-at set index)
                0)))
          (set! index (+ index 1))))
      count)))

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
  (let
    [index : i64 (- (compiler-live-set-word-count set) 1)]
    [score : i64 0]
    (begin
      (while (>= index 0)
        (begin
          (set!
            score
            (compiler-live-set-score-word-desc
              (compiler-live-set-word-at set index)
              (* index (compiler-live-set-word-bits))
              (- (compiler-live-set-word-bits) 1)
              score))
          (set! index (- index 1))))
      score)))

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

(define (compiler-live-set4 [a : i64] [b : i64] [c : i64] [d : i64]) : CompilerLiveI64Set
  (compiler-live-set-insert
    (compiler-live-set-insert
      (compiler-live-set-insert
        (compiler-live-set-insert (compiler-live-set-empty) a)
        b)
      c)
    d))

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

(define (compiler-live-set-ops-ok?) : bool
  (let
    [empty : CompilerLiveI64Set (compiler-live-set-empty)]
    [with-negative : CompilerLiveI64Set (compiler-live-set-insert empty -4)]
    [a : CompilerLiveI64Set (compiler-live-set4 0 62 63 130)]
    [b : CompilerLiveI64Set (compiler-live-set4 130 63 62 0)]
    [removed : CompilerLiveI64Set (compiler-live-set-remove a 62)]
    [unioned : CompilerLiveI64Set
      (compiler-live-set-union removed (compiler-live-set2 62 129))]
    [minus : CompilerLiveI64Set
      (compiler-live-set-minus unioned (compiler-live-set2 0 129))]
    [trimmed : CompilerLiveI64Set
      (compiler-live-set-remove (compiler-live-set-remove a 130) 63)]
    [ok : bool true]
    (begin
      (set! ok (and ok (compiler-live-set-eq? empty with-negative)))
      (set! ok (and ok (= (compiler-live-set-count a) 4)))
      (set! ok (and ok (compiler-live-set-contains? a 0)))
      (set! ok (and ok (compiler-live-set-contains? a 62)))
      (set! ok (and ok (compiler-live-set-contains? a 63)))
      (set! ok (and ok (compiler-live-set-contains? a 130)))
      (set! ok (and ok (not (compiler-live-set-contains? a -1))))
      (set! ok (and ok (not (compiler-live-set-contains? a 64))))
      (set! ok (and ok (compiler-live-set-eq? a b)))
      (set!
        ok
        (and ok (= (compiler-live-set-score a) (compiler-live-set-score b))))
      (set! ok (and ok (= (compiler-live-set-count removed) 3)))
      (set! ok (and ok (not (compiler-live-set-contains? removed 62))))
      (set! ok (and ok (= (compiler-live-set-count unioned) 5)))
      (set!
        ok
        (and ok (compiler-live-set-eq? minus (compiler-live-set3 62 63 130))))
      (set! ok (and ok (= (compiler-live-set-count trimmed) 2)))
      (set! ok (and ok (= (compiler-live-set-word-count trimmed) 1)))
      ok)))

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
        (compiler-live-label-set-contains? (box-get rest) value))]))

(define (compiler-live-label-set-insert
  [set : CompilerLiveLabelSet]
  [value : String]) : CompilerLiveLabelSet
  (if (compiler-live-label-set-contains? set value)
    set
    (CompilerLiveLabelCons value (box set))))

(define (compiler-live-label-set-count [set : CompilerLiveLabelSet]) : i64
  (match set
    [(CompilerLiveLabelNil) 0]
    [(CompilerLiveLabelCons _ rest)
      (+ 1 (compiler-live-label-set-count (box-get rest)))]))

(define (compiler-live-value-vars [value : CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(IrValueVar id) (compiler-live-set1 id)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-value-vars-into
  [set : CompilerLiveI64Set]
  [value : CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(IrValueVar id) (compiler-live-set-insert set id)]
    [_ set]))

(define (compiler-live-values2-vars [a : CompilerIrValue] [b : CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-value-vars b) a))

(define (compiler-live-values3-vars
  [a : CompilerIrValue]
  [b : CompilerIrValue]
  [c : CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-values2-vars b c) a))

(define (compiler-live-values4-vars
  [a : CompilerIrValue]
  [b : CompilerIrValue]
  [c : CompilerIrValue]
  [d : CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-values3-vars b c d) a))

(define (compiler-live-value-list-vars [values : CompilerIrValueList]) : CompilerLiveI64Set
  (match values
    [(IrValueNil) (compiler-live-set-empty)]
    [(IrValueCons value rest)
      (compiler-live-value-vars-into
        (compiler-live-value-list-vars (box-get rest))
        value)]))

(define (compiler-live-call-args-array-vars
  [values : (Array CompilerIrValue)]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (array-length values))
    (compiler-live-set-empty)
    (compiler-live-value-vars-into
      (compiler-live-call-args-array-vars values (+ index 1))
      (array-ref values index))))

(define (compiler-live-call-args-vars [args : CompilerIrCallArgs]) : CompilerLiveI64Set
  (match args
    [(IrCallArgsNil) (compiler-live-set-empty)]
    [(IrCallArgsOne value) (compiler-live-value-vars value)]
    [(IrCallArgsTwo a b) (compiler-live-values2-vars a b)]
    [(IrCallArgsArray values) (compiler-live-call-args-array-vars values 0)]))

(define (compiler-live-maybe-value-vars [value : CompilerIrMaybeValue]) : CompilerLiveI64Set
  (match value
    [(IrNoValue) (compiler-live-set-empty)]
    [(IrSomeValue inner) (compiler-live-value-vars inner)]))

(define (compiler-live-phi-input-vars [inputs : CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match inputs
    [(IrPhiInputNil) (compiler-live-set-empty)]
    [(IrPhiInputCons value _ rest)
      (compiler-live-value-vars-into
        (compiler-live-phi-input-vars (box-get rest))
        value)]))

(define (compiler-live-switch-case-successors
  [set : CompilerLiveLabelSet]
  [cases : CompilerIrSwitchCaseList]) : CompilerLiveLabelSet
  (match cases
    [(IrSwitchCaseNil) set]
    [(IrSwitchCaseCons case rest)
      (match case
        [(IrSwitchCase _ label)
          (compiler-live-switch-case-successors
            (compiler-live-label-set-insert set label)
            (box-get rest))])]))

(define (compiler-live-instr-uses [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov _ src _) (compiler-live-value-vars src)]
    [(IrInstrAlloc _ _) (compiler-live-set-empty)]
    [(IrInstrAddrOf _ src) (compiler-live-set1 src)]
    [(IrInstrGep _ base offset _) (compiler-live-values2-vars base offset)]
    [(IrInstrLoad _ src _) (compiler-live-value-vars src)]
    [(IrInstrStorePtr dst src _) (compiler-live-values2-vars dst src)]
    [(IrInstrCopyBytes dst src _) (compiler-live-values2-vars dst src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-live-values2-vars index length)]
    [(IrInstrCast _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrBitcast _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrBinOp _ _ lhs rhs _) (compiler-live-values2-vars lhs rhs)]
    [(IrInstrUnOp _ _ src _) (compiler-live-value-vars src)]
    [(IrInstrLaneId _ _ _) (compiler-live-set-empty)]
    [(IrInstrSplat _ value _ _) (compiler-live-value-vars value)]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload _ _ lhs rhs _ _)
          (compiler-live-values2-vars lhs rhs)])]
    [(IrInstrVectorReduce _ _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload _ _ lhs rhs _ _)
          (compiler-live-values2-vars lhs rhs)])]
    [(IrInstrMaskBinOp _ _ lhs rhs _) (compiler-live-values2-vars lhs rhs)]
    [(IrInstrMaskNot _ src _) (compiler-live-value-vars src)]
    [(IrInstrMaskReduce _ _ src _) (compiler-live-value-vars src)]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload _ mask on-true on-false _ _)
          (compiler-live-values3-vars mask on-true on-false)])]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-live-values2-vars base index)]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload base index value _ _)
          (compiler-live-values3-vars base index value)])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload base index value mask _ _)
          (compiler-live-values4-vars base index value mask)])]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload _ base index mask _ _)
          (compiler-live-values3-vars base index mask)])]
    [(IrInstrTailMask _ index len _) (compiler-live-values2-vars index len)]
    [(IrInstrEntryArgc _) (compiler-live-set-empty)]
    [(IrInstrEntryArgv _) (compiler-live-set-empty)]
    [(IrInstrEntryEnvp _) (compiler-live-set-empty)]
    [(IrInstrCpuId _ leaf subleaf _) (compiler-live-values2-vars leaf subleaf)]
    [(IrInstrXgetbv _ index) (compiler-live-value-vars index)]
    [(IrInstrSyscall _ args) (compiler-live-call-args-vars args)]
    [(IrInstrCall _ _ args _) (compiler-live-call-args-vars args)]
    [(IrInstrCallIndirect _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(IrInstrCallIndirectC _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload base _ args _)
          (compiler-live-value-vars-into
            (compiler-live-call-args-vars args)
            base)])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload base func args _)
          (compiler-live-value-vars-into
            (compiler-live-value-vars-into
              (compiler-live-call-args-vars args)
              base)
            func)])]
    [(IrInstrTailCall _ args _) (compiler-live-call-args-vars args)]
    [(IrInstrStore _ value _) (compiler-live-value-vars value)]
    [(IrInstrBranch cond _ _) (compiler-live-value-vars cond)]
    [(IrInstrReturn value) (compiler-live-maybe-value-vars value)]
    [(IrInstrPhi _ inputs _) (compiler-live-phi-input-vars inputs)]
    [(IrInstrPack _ words _) (compiler-live-value-list-vars words)]
    [(IrInstrWord _ src _ _) (compiler-live-value-vars src)]
    [(IrInstrJump _) (compiler-live-set-empty)]
    [(IrInstrTailCallIndirect func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(IrInstrSwitch index _ _ _) (compiler-live-value-vars index)]))

(define (compiler-live-instr-defs [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov dst _ _) (compiler-live-set1 dst)]
    [(IrInstrAlloc dst _) (compiler-live-set1 dst)]
    [(IrInstrAddrOf dst _) (compiler-live-set1 dst)]
    [(IrInstrGep dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrLoad dst _ _) (compiler-live-set1 dst)]
    [(IrInstrCast dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrBitcast dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrUnOp dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrLaneId dst _ _) (compiler-live-set1 dst)]
    [(IrInstrSplat dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(IrInstrVectorReduce dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set1 dst)]
    [(IrInstrMaskReduce dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ _ _ _ _) (compiler-live-set1 dst)])]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set1 dst)]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(IrInstrTailMask dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrEntryArgc dst) (compiler-live-set1 dst)]
    [(IrInstrEntryArgv dst) (compiler-live-set1 dst)]
    [(IrInstrEntryEnvp dst) (compiler-live-set1 dst)]
    [(IrInstrCpuId dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrXgetbv dst _) (compiler-live-set1 dst)]
    [(IrInstrSyscall dst _) (compiler-live-set1 dst)]
    [(IrInstrCall dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrCallIndirect dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrCallIndirectC dst _ _ _) (compiler-live-set1 dst)]
    [(IrInstrPhi dst _ _) (compiler-live-set1 dst)]
    [(IrInstrPack dst _ _) (compiler-live-set1 dst)]
    [(IrInstrWord dst _ _ _) (compiler-live-set1 dst)]
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
          (box-get rest)
          (compiler-live-set-union
            uses
            (compiler-live-set-minus instr-uses defs))
          (compiler-live-set-union defs instr-defs)))]))

(define (compiler-live-block-use-def [instrs : CompilerIrInstrList]) : CompilerLiveUseDef
  (compiler-live-block-use-def-instrs
    instrs
    (compiler-live-set-empty)
    (compiler-live-set-empty)))

(define (compiler-live-block-use-def-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (CompilerLiveUseDef uses defs)
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      [instr-uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
      [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
      (compiler-live-block-use-def-seq-from
        instrs
        (+ index 1)
        (compiler-live-set-union uses (compiler-live-set-minus instr-uses defs))
        (compiler-live-set-union defs instr-defs)))))

(define (compiler-live-block-use-def-seq [instrs : CompilerIrInstrSeq]) : CompilerLiveUseDef
  (compiler-live-block-use-def-seq-from
    instrs
    0
    (compiler-live-set-empty)
    (compiler-live-set-empty)))

(define (compiler-live-instr-list-last [instrs : CompilerIrInstrList]) : CompilerLiveMaybeInstr
  (match instrs
    [(IrInstrNil) CompilerLiveNoInstr]
    [(IrInstrCons instr rest)
      (match (box-get rest)
        [(IrInstrNil) (CompilerLiveSomeInstr instr)]
        [_ (compiler-live-instr-list-last (box-get rest))])]))

(define (compiler-live-instr-seq-last [instrs : CompilerIrInstrSeq]) : CompilerLiveMaybeInstr
  (if (compiler-ir-instr-seq-empty? instrs)
    CompilerLiveNoInstr
    (CompilerLiveSomeInstr
      (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1)))))

(define (compiler-live-block-successors [block : CompilerIrBlock]) : CompilerLiveLabelSet
  (match block
    [(IrBlock _ instrs)
      (match (compiler-live-instr-seq-last instrs)
        [(CompilerLiveNoInstr) CompilerLiveLabelNil]
        [(CompilerLiveSomeInstr instr)
          (match instr
            [(IrInstrJump target)
              (CompilerLiveLabelCons target (box CompilerLiveLabelNil))]
            [(IrInstrBranch _ true-label false-label)
              (compiler-live-label-set-insert
                (CompilerLiveLabelCons true-label (box CompilerLiveLabelNil))
                false-label)]
            [(IrInstrSwitch _ _ cases default-label)
              (compiler-live-switch-case-successors
                (CompilerLiveLabelCons default-label (box CompilerLiveLabelNil))
                cases)]
            [_ CompilerLiveLabelNil])])]))

(define (compiler-live-build-block [block : CompilerIrBlock]) : CompilerLiveBlock
  (match block
    [(IrBlock label instrs)
      (match (compiler-live-block-use-def-seq instrs)
        [(CompilerLiveUseDef uses defs)
          (CompilerLiveBlock
            label
            uses
            defs
            (compiler-live-set-empty)
            (compiler-live-set-empty)
            (compiler-live-block-successors block)
            (compiler-live-instr-set-vec-empty))])]))

(define (compiler-live-build-blocks [blocks : CompilerIrBlockList]) : CompilerLiveBlockList
  (match blocks
    [(IrBlockNil) CompilerLiveBlockNil]
    [(IrBlockCons block rest)
      (compiler-live-block-cons
        (compiler-live-build-block block)
        (compiler-live-build-blocks (box-get rest)))]
    [(IrBlockArray seq)
      (compiler-live-build-blocks (compiler-ir-block-seq-to-list seq))]))

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
            (compiler-live-find-block (box-get rest) label))])]))

(define (compiler-live-block-count [blocks : CompilerLiveBlockList]) : i64
  (match blocks
    [(CompilerLiveBlockNil) 0]
    [(CompilerLiveBlockCons _ rest)
      (+ 1 (compiler-live-block-count (box-get rest)))]))

(define (compiler-live-block-graph-fill!
  [blocks : CompilerLiveBlockList]
  [ids : StringI64Map]
  [values : (Array CompilerLiveBlock)]
  [index : i64]) : StringI64Map
  (match blocks
    [(CompilerLiveBlockNil) ids]
    [(CompilerLiveBlockCons block rest)
      (match block
        [(CompilerLiveBlock label _ _ _ _ _ _)
          (begin
            (array-set! values index block)
            (compiler-live-block-graph-fill!
              (box-get rest)
              (if (string-i64-map-contains? ids label)
                ids
                (string-i64-map-put ids label index))
              values
              (+ index 1)))])]))

(define (compiler-live-block-graph-build [blocks : CompilerLiveBlockList]) : CompilerLiveBlockGraph
  (let
    [count : i64 (compiler-live-block-count blocks)]
    [values : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
    [successors : (Array CompilerLiveIndexVec)
      (make-array CompilerLiveIndexVec count)]
    [ids : StringI64Map
      (compiler-live-block-graph-fill!
        blocks
        (string-i64-map-with-capacity (+ (* count 2) 1))
        values
        0)]
    (begin
      (compiler-live-block-graph-fill-successors! blocks ids successors 0)
      (CompilerLiveBlockGraph ids values successors))))

(define (compiler-live-label-set-index-count
  [labels : CompilerLiveLabelSet]
  [ids : StringI64Map]) : i64
  (match labels
    [(CompilerLiveLabelNil) 0]
    [(CompilerLiveLabelCons label rest)
      (let
        [rest-count : i64
          (compiler-live-label-set-index-count (box-get rest) ids)]
        (match (string-i64-map-get ids label)
          [(StringI64MapFound _) (+ rest-count 1)]
          [(StringI64MapMissing) rest-count]))]))

(define (compiler-live-label-set-fill-indexes!
  [labels : CompilerLiveLabelSet]
  [ids : StringI64Map]
  [items : (Array i64)]
  [index : i64]) : i64
  (match labels
    [(CompilerLiveLabelNil) index]
    [(CompilerLiveLabelCons label rest)
      (match (string-i64-map-get ids label)
        [(StringI64MapFound slot)
          (begin
            (array-set! items index slot)
            (compiler-live-label-set-fill-indexes!
              (box-get rest)
              ids
              items
              (+ index 1)))]
        [(StringI64MapMissing)
          (compiler-live-label-set-fill-indexes! (box-get rest) ids items index)])]))

(define (compiler-live-label-set-to-index-vec
  [labels : CompilerLiveLabelSet]
  [ids : StringI64Map]) : CompilerLiveIndexVec
  (let
    [count : i64 (compiler-live-label-set-index-count labels ids)]
    [items : (Array i64) (make-array i64 count)]
    (begin
      (compiler-live-label-set-fill-indexes! labels ids items 0)
      (CompilerLiveIndexVec items))))

(define (compiler-live-block-graph-fill-successors!
  [blocks : CompilerLiveBlockList]
  [ids : StringI64Map]
  [successors : (Array CompilerLiveIndexVec)]
  [index : i64]) : unit
  (match blocks
    [(CompilerLiveBlockNil) unit]
    [(CompilerLiveBlockCons block rest)
      (match block
        [(CompilerLiveBlock _ _ _ _ _ block-successors _)
          (begin
            (array-set!
              successors
              index
              (compiler-live-label-set-to-index-vec block-successors ids))
            (compiler-live-block-graph-fill-successors!
              (box-get rest)
              ids
              successors
              (+ index 1)))])]))

(define (compiler-live-graph-find-block
  [graph : CompilerLiveBlockGraph]
  [label : String]) : CompilerLiveMaybeBlock
  (match (string-i64-map-get (struct-get graph ids) label)
    [(StringI64MapFound slot)
      (CompilerLiveSomeBlock (array-ref (struct-get graph blocks) slot))]
    [(StringI64MapMissing) CompilerLiveNoBlock]))

(define (compiler-live-successor-live-out-graph-loop
  [items : (Array i64)]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [acc : CompilerLiveI64Set]) : CompilerLiveI64Set
  (if (>= index (array-length items))
    acc
    (match (array-ref (struct-get graph blocks) (array-ref items index))
      [(CompilerLiveBlock _ _ _ live-in _ _ _)
        (compiler-live-successor-live-out-graph-loop
          items
          graph
          (+ index 1)
          (compiler-live-set-union live-in acc))])))

(define (compiler-live-successor-live-out-graph
  [successors : CompilerLiveIndexVec]
  [graph : CompilerLiveBlockGraph]) : CompilerLiveI64Set
  (compiler-live-successor-live-out-graph-loop
    (struct-get successors items)
    graph
    0
    (compiler-live-set-empty)))

(define (compiler-live-recompute-block-graph
  [block : CompilerLiveBlock]
  [graph : CompilerLiveBlockGraph]
  [index : i64]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock label uses defs _ _ successors instr-after)
      (let
        [live-out : CompilerLiveI64Set
          (compiler-live-successor-live-out-graph
            (array-ref (struct-get graph successors) index)
            graph)]
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

(define (compiler-live-successor-live-out
  [successors : CompilerLiveLabelSet]
  [blocks : CompilerLiveBlockList]) : CompilerLiveI64Set
  (match successors
    [(CompilerLiveLabelNil) (compiler-live-set-empty)]
    [(CompilerLiveLabelCons label rest)
      (let
        [rest-live : CompilerLiveI64Set
          (compiler-live-successor-live-out (box-get rest) blocks)]
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
        (match (compiler-live-update-blocks (box-get rest) all-blocks)
          [(CompilerLiveBlockListStep updated-rest rest-changed)
            (CompilerLiveBlockListStep
              (compiler-live-block-cons updated updated-rest)
              (if (compiler-live-block-liveness-eq? block updated)
                rest-changed
                true))]))]))

(define (compiler-live-graph-update! [graph : CompilerLiveBlockGraph]) : bool
  (let
    [blocks : (Array CompilerLiveBlock) (struct-get graph blocks)]
    [count : i64 (array-length blocks)]
    [index : i64 (- count 1)]
    [changed : bool false]
    (begin
      (while (>= index 0)
        (let
          [block : CompilerLiveBlock (array-ref blocks index)]
          [updated : CompilerLiveBlock
            (compiler-live-recompute-block-graph block graph index)]
          (begin
            (if (compiler-live-block-liveness-eq? block updated)
              unit
              (begin
                (array-set! blocks index updated)
                (set! changed true)))
            (set! index (- index 1)))))
      changed)))

(define (compiler-live-graph-to-list-from
  [blocks : (Array CompilerLiveBlock)]
  [index : i64]
  [acc : CompilerLiveBlockList]) : CompilerLiveBlockList
  (if (< index 0)
    acc
    (compiler-live-graph-to-list-from
      blocks
      (- index 1)
      (compiler-live-block-cons (array-ref blocks index) acc))))

(define (compiler-live-graph-to-list [graph : CompilerLiveBlockGraph]) : CompilerLiveBlockList
  (let
    [blocks : (Array CompilerLiveBlock) (struct-get graph blocks)]
    (compiler-live-graph-to-list-from
      blocks
      (- (array-length blocks) 1)
      CompilerLiveBlockNil)))

(define (compiler-live-fixpoint [blocks : CompilerLiveBlockList]) : CompilerLiveBlockGraph
  (let
    [graph : CompilerLiveBlockGraph (compiler-live-block-graph-build blocks)]
    [done : bool false]
    (begin
      (while (not done)
        (set! done (not (compiler-live-graph-update! graph))))
      graph)))

(define (compiler-live-before-instr
  [live-after : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (compiler-live-set-union
    (compiler-live-instr-uses instr)
    (compiler-live-set-minus live-after (compiler-live-instr-defs instr))))

(define (compiler-live-instr-seq-scan-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [live-after : CompilerLiveI64Set]
  [out : (Array CompilerLiveI64Set)]) : CompilerLiveI64Set
  (if (< index 0)
    live-after
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (begin
        (array-set! out index live-after)
        (compiler-live-instr-seq-scan-from
          instrs
          (- index 1)
          (compiler-live-before-instr live-after instr)
          out)))))

(define (compiler-live-instr-seq-scan
  [instrs : CompilerIrInstrSeq]
  [live-out : CompilerLiveI64Set]) : CompilerLiveInstrScan
  (let
    [count : i64 (compiler-ir-instr-seq-count instrs)]
    [items : (Array CompilerLiveI64Set) (make-array CompilerLiveI64Set count)]
    [live-before : CompilerLiveI64Set
      (compiler-live-instr-seq-scan-from instrs (- count 1) live-out items)]
    (CompilerLiveInstrScan (CompilerLiveInstrSetVec items) live-before)))

(define (compiler-live-fill-instr-after-block
  [ir-block : CompilerIrBlock]
  [block : CompilerLiveBlock]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock label uses defs live-in live-out successors _)
      (match ir-block
        [(IrBlock _ instrs)
          (match (compiler-live-instr-seq-scan instrs live-out)
            [(CompilerLiveInstrScan instr-after _)
              (CompilerLiveBlock
                label
                uses
                defs
                live-in
                live-out
                successors
                instr-after)])])]))

(define (compiler-live-fill-instr-after-graph-cons!
  [ir-blocks : CompilerIrBlockList]
  [blocks : (Array CompilerLiveBlock)]
  [index : i64]) : unit
  (match ir-blocks
    [(IrBlockNil) unit]
    [(IrBlockCons ir-block rest)
      (if (>= index (array-length blocks))
        unit
        (begin
          (array-set!
            blocks
            index
            (compiler-live-fill-instr-after-block
              ir-block
              (array-ref blocks index)))
          (compiler-live-fill-instr-after-graph-cons!
            (box-get rest)
            blocks
            (+ index 1))))]
    [(IrBlockArray seq)
      (let
        [i : i64 0]
        [count : i64
          (compiler-live-set-min
            (compiler-ir-block-seq-count seq)
            (- (array-length blocks) index))]
        (while (< i count)
          (let
            [slot : i64 (+ index i)]
            (begin
              (array-set!
                blocks
                slot
                (compiler-live-fill-instr-after-block
                  (compiler-ir-block-seq-ref seq i)
                  (array-ref blocks slot)))
              (set! i (+ i 1))))))]))

(define (compiler-live-fill-instr-after-graph!
  [ir-blocks : CompilerIrBlockList]
  [graph : CompilerLiveBlockGraph]) : unit
  (compiler-live-fill-instr-after-graph-cons!
    ir-blocks
    (struct-get graph blocks)
    0))

(define (compiler-live-analyze-function [func : CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(IrFunction _ _ _ _ blocks)
      (let
        [walk-blocks : CompilerIrBlockList
          (compiler-ir-block-list-force-cons blocks)]
        [graph : CompilerLiveBlockGraph
          (compiler-live-fixpoint (compiler-live-build-blocks walk-blocks))]
        (begin
          (compiler-live-fill-instr-after-graph! walk-blocks graph)
          (CompilerFunctionLiveness
            (struct-get graph ids)
            (struct-get graph blocks))))]))

(define (compiler-live-function-blocks [liveness : CompilerFunctionLiveness]) : CompilerLiveBlockList
  (match liveness
    [(CompilerFunctionLiveness _ blocks)
      (compiler-live-graph-to-list-from
        blocks
        (- (array-length blocks) 1)
        CompilerLiveBlockNil)]))

(define (compiler-live-function-block-count
  [liveness : CompilerFunctionLiveness]) : i64
  (match liveness
    [(CompilerFunctionLiveness _ blocks) (array-length blocks)]))

(define (compiler-live-function-block-ref
  [liveness : CompilerFunctionLiveness]
  [index : i64]) : CompilerLiveBlock
  (match liveness
    [(CompilerFunctionLiveness _ blocks) (array-ref blocks index)]))

(define (compiler-live-function-find-block
  [liveness : CompilerFunctionLiveness]
  [label : String]) : CompilerLiveMaybeBlock
  (match liveness
    [(CompilerFunctionLiveness ids blocks)
      (match (string-i64-map-get ids label)
        [(StringI64MapFound index)
          (CompilerLiveSomeBlock (array-ref blocks index))]
        [(StringI64MapMissing) CompilerLiveNoBlock])]))

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

(define (compiler-live-block-instr-after [block : CompilerLiveBlock]) : CompilerLiveInstrSetVec
  (match block
    [(CompilerLiveBlock _ _ _ _ _ _ instr-after) instr-after]))

(define (compiler-live-instr-set-vec-nth
  [sets : CompilerLiveInstrSetVec]
  [index : i64]) : CompilerLiveI64Set
  (let
    [items : (Array CompilerLiveI64Set) (struct-get sets items)]
    (if (or (< index 0) (>= index (array-length items)))
      (compiler-live-set-empty)
      (array-ref items index))))

(define (compiler-live-after
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [index : i64]) : CompilerLiveI64Set
  (match (compiler-live-function-find-block liveness label)
    [(CompilerLiveSomeBlock block)
      (compiler-live-instr-set-vec-nth
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
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 1) (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              1
              IrBinAdd
              (IrValueVar 0)
              (IrValueVar 2)
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              IrInstrNil))))
      IrBlockNil)))

(define (compiler-live-branch-function) : CompilerIrFunction
  (IrFunction
    "branch"
    IrParamNil
    (compiler-live-i64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          IrInstrNil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "then"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            IrInstrNil))
        (compiler-ir-block-cons
          (compiler-ir-block
            "else"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 2)))
              IrInstrNil))
          IrBlockNil)))))

(define (compiler-live-phi-function) : CompilerIrFunction
  (IrFunction
    "phi"
    IrParamNil
    (compiler-live-i64-ty)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "left" "right")
          IrInstrNil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "left"
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 10) (compiler-live-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "right"
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueI64 20) (compiler-live-i64-ty))
              (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "join"
              (compiler-ir-instr-cons
                (IrInstrPhi
                  3
                  (compiler-ir-phi-input-cons
                    (IrValueVar 1)
                    "left"
                    (compiler-ir-phi-input-cons
                      (IrValueVar 2)
                      "right"
                      IrPhiInputNil))
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  IrInstrNil)))
            IrBlockNil))))))

(define (compiler-live-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (IrInstrMov 0 (IrValueVar 10) (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (IrInstrBinOp
          1
          IrBinAdd
          (IrValueVar 0)
          (IrValueVar 11)
          (compiler-live-i64-ty))
        (compiler-ir-instr-cons
          (IrInstrUnOp 2 IrUnNeg (IrValueVar 12) (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall
              3
              "f"
              (IrCallArgsTwo (IrValueVar 1) (IrValueVar 13))
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "g" (IrValueVar 14) (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 15) "a" "b")
                (compiler-ir-instr-cons
                  (IrInstrPhi
                    4
                    (compiler-ir-phi-input-cons
                      (IrValueVar 16)
                      "a"
                      IrPhiInputNil)
                    (compiler-live-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                    IrInstrNil)))))))))
    [(CompilerLiveUseDef uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set7 10 11 12 13 14 15 16))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-memory-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (IrInstrAlloc 0 (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (IrInstrAddrOf 1 0)
        (compiler-ir-instr-cons
          (IrInstrGep 2 (IrValueVar 1) (IrValueVar 10) (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 2) (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStorePtr
                (IrValueVar 2)
                (IrValueVar 11)
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrCast 4 (IrValueVar 3) (compiler-live-i64-ty) (AstTyI32))
                IrInstrNil)))))))
    [(CompilerLiveUseDef uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set2 10 11))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (IrInstrLaneId 0 4 (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (IrInstrSplat 1 (IrValueVar 10) 4 (compiler-live-i64-ty))
        (compiler-ir-instr-cons
          (ir-instr-vector-bin-op
            2
            (IrBinAdd)
            (IrValueVar 0)
            (IrValueVar 1)
            4
            (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrTailMask 3 (IrValueVar 11) (IrValueVar 12) 4)
            (compiler-ir-instr-cons
              (ir-instr-predicated-load
                4
                (IrValueVar 13)
                (IrValueVar 11)
                (IrValueVar 3)
                4
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (ir-instr-predicated-store
                  (IrValueVar 14)
                  (IrValueVar 11)
                  (IrValueVar 2)
                  (IrValueVar 3)
                  4
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
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
    (match (compiler-live-function-find-block liveness "entry")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (compiler-live-set1 2))
          (compiler-live-set-eq?
            (compiler-live-block-defs block)
            (compiler-live-set2 0 1))
          (compiler-live-set-eq?
            (compiler-live-block-live-in block)
            (compiler-live-set1 2))
          (compiler-live-set-eq?
            (compiler-live-block-live-out block)
            (compiler-live-set-empty))
          (compiler-live-set-eq?
            (compiler-live-after liveness "entry" 0)
            (compiler-live-set2 0 2))
          (compiler-live-set-eq?
            (compiler-live-after liveness "entry" 1)
            (compiler-live-set1 1))
          (compiler-live-set-eq?
            (compiler-live-after liveness "entry" 2)
            (compiler-live-set-empty)))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))]
    (match (compiler-live-function-find-block liveness "entry")
      [(CompilerLiveSomeBlock block)
        (and
          (=
            (compiler-live-label-set-count
              (compiler-live-block-successor-labels block))
            2)
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            "then")
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            "else")
          (compiler-live-set-eq?
            (compiler-live-block-live-in block)
            (compiler-live-set3 0 1 2)))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))]
    (match (compiler-live-function-find-block liveness "join")
      [(CompilerLiveSomeBlock block)
        (and
          (compiler-live-set-eq?
            (compiler-live-block-uses block)
            (compiler-live-set2 1 2))
          (compiler-live-set-eq?
            (compiler-live-block-defs block)
            (compiler-live-set1 3))
          (compiler-live-set-eq?
            (compiler-live-block-live-in block)
            (compiler-live-set2 1 2))
          (compiler-live-set-eq?
            (compiler-live-after liveness "join" 0)
            (compiler-live-set1 3))
          (match (compiler-live-function-find-block liveness "left")
            [(CompilerLiveSomeBlock left-block)
              (compiler-live-label-set-contains?
                (compiler-live-block-successor-labels left-block)
                "join")]
            [(CompilerLiveNoBlock) false]))]
      [(CompilerLiveNoBlock) false])))

(define (compiler-live-switch-ok?) : bool
  (let
    [cases : CompilerIrSwitchCaseList
      (compiler-ir-switch-case-cons
        4
        "four"
        (compiler-ir-switch-case-cons 5 "five" IrSwitchCaseNil))]
    [instr : CompilerIrInstr (IrInstrSwitch (IrValueVar 9) 4 cases "other")]
    [instrs : CompilerIrInstrList (compiler-ir-instr-cons instr IrInstrNil)]
    [block : CompilerIrBlock (compiler-ir-block "entry" instrs)]
    [successors : CompilerLiveLabelSet (compiler-live-block-successors block)]
    (match (compiler-live-block-use-def instrs)
      [(CompilerLiveUseDef uses defs)
        (and
          (compiler-live-set-eq? uses (compiler-live-set1 9))
          (compiler-live-set-eq? defs (compiler-live-set-empty))
          (= (compiler-live-label-set-count successors) 3)
          (compiler-live-label-set-contains? successors "four")
          (compiler-live-label-set-contains? successors "five")
          (compiler-live-label-set-contains? successors "other"))])))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-set-ops-ok?)
    (compiler-live-use-def-ok?)
    (compiler-live-memory-use-def-ok?)
    (compiler-live-vector-mask-use-def-ok?)
    (compiler-live-straight-ok?)
    (compiler-live-branch-ok?)
    (compiler-live-phi-ok?)
    (compiler-live-switch-ok?))
    42
    (begin
      (panic "liveness: smoke mismatch")
      ;; lint-allow: unreachable-code
      0)))