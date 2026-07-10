;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis.
;;
;; This module keeps the selfhost liveness pass deterministic while storing
;; integer live sets as compact bitsets keyed by dense IR variable ids. Do not
;; replace CompilerLiveI64Set with the general `(set i64)` family without a
;; compiler-path benchmark: opt2 self-compile is sensitive to liveness set
;; iteration and copy costs.
(import stdlib.io)
(import stdlib.string)
(import "compiler_ir_types.tl")
(import stdlib.hashmap)
(import (hashmap String i64) as live_label_map)

(defstruct CompilerLiveI64Set
  (words (Array i64)))

(defenum CompilerLiveLabelSet
  (Nil)
  (Cons String (Box CompilerLiveLabelSet)))

(defstruct CompilerLiveIndexVec
  (items (Array i64)))

(defstruct CompilerLiveInstrSetVec
  (items (Array CompilerLiveI64Set)))

(defenum CompilerLiveBlock
  (Block
    String
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveI64Set
    CompilerLiveLabelSet
    CompilerLiveInstrSetVec))

(defenum CompilerLiveBlockList
  (Nil)
  (Cons CompilerLiveBlock (Box CompilerLiveBlockList)))

(defstruct CompilerLiveBlockGraph
  (ids live_label_map.Map)
  (blocks (Array CompilerLiveBlock))
  (successors (Array CompilerLiveIndexVec)))

(defenum CompilerFunctionLiveness
  (Liveness live_label_map.Map (Array CompilerLiveBlock)))

(defenum CompilerLiveMaybeBlock
  (No)
  (Some CompilerLiveBlock))

(defenum CompilerLiveMaybeInstr
  (No)
  (Some CompilerIrInstr))

(defenum CompilerLiveUseDef
  (Def CompilerLiveI64Set CompilerLiveI64Set))

(defenum CompilerLiveBlockListStep
  (Step CompilerLiveBlockList bool))

(defenum CompilerLiveInstrScan
  (Scan CompilerLiveInstrSetVec CompilerLiveI64Set))

(define (compiler-live-instr-set-vec-empty) : CompilerLiveInstrSetVec
  (CompilerLiveInstrSetVec (make-array CompilerLiveI64Set 0)))

(define (compiler-live-block-cons
  [head : CompilerLiveBlock]
  [rest : CompilerLiveBlockList]) : CompilerLiveBlockList
  (CompilerLiveBlockList.Cons head (box rest)))

(define (compiler-live-set-word-bits) : i64
  32)

(define (compiler-live-set-word-shift) : i64
  5)

(define (compiler-live-set-word-mask) : i64
  31)

(define (compiler-live-set-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (compiler-live-set-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-live-set-word-index [value : i64]) : i64
  (shr value (compiler-live-set-word-shift)))

(define (compiler-live-set-bit-index [value : i64]) : i64
  (bit-and value (compiler-live-set-word-mask)))

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

;; True iff `a` and `b` share at least one element (bitset word-level AND). Used
;; by the SplitKit phi-carried loop homing to test whether ANY member of a
;; coalesce group is live across a region boundary edge (no single member is live
;; on every boundary edge of a phi-carried value, so the per-var live-on-edge test
;; is insufficient -- the group/slot is what must be loaded/stored).
(define (compiler-live-set-intersects?
  [a : CompilerLiveI64Set]
  [b : CompilerLiveI64Set]) : bool
  (let
    [na : i64 (compiler-live-set-word-count a)]
    [nb : i64 (compiler-live-set-word-count b)]
    [n : i64
      (if (< na nb)
        na
        nb)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (not
            (=
              (bit-and
                (compiler-live-set-word-at a i)
                (compiler-live-set-word-at b i))
              0))
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

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
    [a : CompilerLiveI64Set (compiler-live-set4 0 31 32 66)]
    [b : CompilerLiveI64Set (compiler-live-set4 66 32 31 0)]
    [removed : CompilerLiveI64Set (compiler-live-set-remove a 31)]
    [unioned : CompilerLiveI64Set
      (compiler-live-set-union removed (compiler-live-set2 31 65))]
    [minus : CompilerLiveI64Set
      (compiler-live-set-minus unioned (compiler-live-set2 0 65))]
    [trimmed : CompilerLiveI64Set
      (compiler-live-set-remove (compiler-live-set-remove a 66) 32)]
    [ok : bool true]
    (begin
      (set! ok (and ok (compiler-live-set-eq? empty with-negative)))
      (set! ok (and ok (= (compiler-live-set-count a) 4)))
      (set! ok (and ok (compiler-live-set-contains? a 0)))
      (set! ok (and ok (compiler-live-set-contains? a 31)))
      (set! ok (and ok (compiler-live-set-contains? a 32)))
      (set! ok (and ok (compiler-live-set-contains? a 66)))
      (set! ok (and ok (not (compiler-live-set-contains? a -1))))
      (set! ok (and ok (not (compiler-live-set-contains? a 33))))
      (set! ok (and ok (compiler-live-set-eq? a b)))
      (set!
        ok
        (and ok (= (compiler-live-set-score a) (compiler-live-set-score b))))
      (set! ok (and ok (= (compiler-live-set-count removed) 3)))
      (set! ok (and ok (not (compiler-live-set-contains? removed 31))))
      (set! ok (and ok (= (compiler-live-set-count unioned) 5)))
      (set!
        ok
        (and ok (compiler-live-set-eq? minus (compiler-live-set3 31 32 66))))
      (set! ok (and ok (= (compiler-live-set-count trimmed) 2)))
      (set! ok (and ok (= (compiler-live-set-word-count trimmed) 1)))
      ok)))

(define (compiler-live-label-set-empty) : CompilerLiveLabelSet
  CompilerLiveLabelSet.Nil)

(define (compiler-live-label-set-contains?
  [set : CompilerLiveLabelSet]
  [value : String]) : bool
  (match set
    [(CompilerLiveLabelSet.Nil) false]
    [(CompilerLiveLabelSet.Cons head rest)
      (if (string.eq head value)
        true
        (compiler-live-label-set-contains? (box-get rest) value))]))

(define (compiler-live-label-set-insert
  [set : CompilerLiveLabelSet]
  [value : String]) : CompilerLiveLabelSet
  (if (compiler-live-label-set-contains? set value)
    set
    (CompilerLiveLabelSet.Cons value (box set))))

(define (compiler-live-label-set-count [set : CompilerLiveLabelSet]) : i64
  (match set
    [(CompilerLiveLabelSet.Nil) 0]
    [(CompilerLiveLabelSet.Cons _ rest)
      (+ 1 (compiler-live-label-set-count (box-get rest)))]))

(define (compiler-live-value-vars [value : CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(CompilerIrValue.Var id) (compiler-live-set1 id)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-value-vars-into
  [set : CompilerLiveI64Set]
  [value : CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(CompilerIrValue.Var id) (compiler-live-set-insert set id)]
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
  (match (compiler-ir-value-list-force-cons values)
    [(CompilerIrValueList.Nil) (compiler-live-set-empty)]
    [(CompilerIrValueList.Array seq)
      (compiler-live-value-list-vars (compiler-ir-value-seq-to-list seq))]
    [(CompilerIrValueList.Cons value rest)
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
    [(CompilerIrCallArgs.Nil) (compiler-live-set-empty)]
    [(CompilerIrCallArgs.One value) (compiler-live-value-vars value)]
    [(CompilerIrCallArgs.Two a b) (compiler-live-values2-vars a b)]
    [(CompilerIrCallArgs.Array values)
      (compiler-live-call-args-array-vars values 0)]))

(define (compiler-live-spmd-call-args-seq-vars
  [seq : CompilerIrSpmdCallArgSeq]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (struct-get seq len))
    (compiler-live-set-empty)
    (match (array-ref (struct-get seq slots) index)
      [(CompilerIrSpmdCallArg.Arg _ value _)
        (compiler-live-value-vars-into
          (compiler-live-spmd-call-args-seq-vars seq (+ index 1))
          value)])))

(define (compiler-live-spmd-call-args-vars [args : CompilerIrSpmdCallArgList]) : CompilerLiveI64Set
  (match args
    [(CompilerIrSpmdCallArgList.Nil) (compiler-live-set-empty)]
    [(CompilerIrSpmdCallArgList.Cons arg rest)
      (match arg
        [(CompilerIrSpmdCallArg.Arg _ value _)
          (compiler-live-value-vars-into
            (compiler-live-spmd-call-args-vars (box-get rest))
            value)])]
    [(CompilerIrSpmdCallArgList.Array seq)
      (compiler-live-spmd-call-args-seq-vars seq 0)]))

(define (compiler-live-spmd-call-result-defs
  [result : CompilerIrSpmdCallResult]) : CompilerLiveI64Set
  (match result
    [(CompilerIrSpmdCallResult.Unit) (compiler-live-set-empty)]
    [(CompilerIrSpmdCallResult.Value dst _ _) (compiler-live-set1 dst)]))

(define (compiler-live-maybe-value-vars [value : CompilerIrMaybeValue]) : CompilerLiveI64Set
  (match value
    [(CompilerIrMaybeValue.No) (compiler-live-set-empty)]
    [(CompilerIrMaybeValue.Some inner) (compiler-live-value-vars inner)]))

(define (compiler-live-phi-input-vars [inputs : CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match (compiler-ir-phi-input-list-force-cons inputs)
    [(CompilerIrPhiInputList.Nil) (compiler-live-set-empty)]
    [(CompilerIrPhiInputList.Array seq)
      (compiler-live-phi-input-vars (compiler-ir-phi-input-seq-to-list seq))]
    [(CompilerIrPhiInputList.Cons value _ rest)
      (compiler-live-value-vars-into
        (compiler-live-phi-input-vars (box-get rest))
        value)]))

(define (compiler-live-switch-case-successors
  [set : CompilerLiveLabelSet]
  [cases : CompilerIrSwitchCaseList]) : CompilerLiveLabelSet
  (match cases
    [(CompilerIrSwitchCaseList.Nil) set]
    [(CompilerIrSwitchCaseList.Cons case rest)
      (match case
        [(CompilerIrSwitchCase.Case _ label)
          (compiler-live-switch-case-successors
            (compiler-live-label-set-insert set label)
            (box-get rest))])]
    [(CompilerIrSwitchCaseList.Array seq)
      (compiler-live-switch-case-successors
        set
        (compiler-ir-switch-case-seq-to-list seq))]))

(define (compiler-live-instr-uses [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(CompilerIrInstr.Mov _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.Alloc _ _) (compiler-live-set-empty)]
    [(CompilerIrInstr.AddrOf _ src) (compiler-live-set1 src)]
    [(CompilerIrInstr.Gep _ base offset _)
      (compiler-live-values2-vars base offset)]
    [(CompilerIrInstr.Load _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.StorePtr dst src _) (compiler-live-values2-vars dst src)]
    [(CompilerIrInstr.CopyBytes dst src _) (compiler-live-values2-vars dst src)]
    [(CompilerIrInstr.BoundsCheck index length _)
      (compiler-live-values2-vars index length)]
    [(CompilerIrInstr.Cast _ src _ _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.Bitcast _ src _ _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.BinOp _ _ lhs rhs _) (compiler-live-values2-vars lhs rhs)]
    [(CompilerIrInstr.UnOp _ _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.LaneId _ _ _) (compiler-live-set-empty)]
    [(CompilerIrInstr.Splat _ value _ _) (compiler-live-value-vars value)]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload _ _ lhs rhs _ _)
          (compiler-live-values2-vars lhs rhs)])]
    [(CompilerIrInstr.VectorReduce _ _ src _ _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload _ _ lhs rhs _ _)
          (compiler-live-values2-vars lhs rhs)])]
    [(CompilerIrInstr.MaskBinOp _ _ lhs rhs _)
      (compiler-live-values2-vars lhs rhs)]
    [(CompilerIrInstr.MaskNot _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.MaskReduce _ _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload _ mask on-true on-false _ _)
          (compiler-live-values3-vars mask on-true on-false)])]
    [(CompilerIrInstr.VectorLoad _ base index _ _)
      (compiler-live-values2-vars base index)]
    [(CompilerIrInstr.VectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload.Payload base index value _ _)
          (compiler-live-values3-vars base index value)])]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload.Payload
            base
            index
            value
            mask
            _
            _)
          (compiler-live-values4-vars base index value mask)])]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload _ base index mask _ _)
          (compiler-live-values3-vars base index mask)])]
    [(CompilerIrInstr.TailMask _ index len _)
      (compiler-live-values2-vars index len)]
    [(CompilerIrInstr.EntryArgc _) (compiler-live-set-empty)]
    [(CompilerIrInstr.EntryArgv _) (compiler-live-set-empty)]
    [(CompilerIrInstr.EntryEnvp _) (compiler-live-set-empty)]
    [(CompilerIrInstr.CpuId _ leaf subleaf _)
      (compiler-live-values2-vars leaf subleaf)]
    [(CompilerIrInstr.Xgetbv _ index) (compiler-live-value-vars index)]
    [(CompilerIrInstr.Syscall _ args) (compiler-live-call-args-vars args)]
    [(CompilerIrInstr.Call _ _ args _) (compiler-live-call-args-vars args)]
    [(CompilerIrInstr.CallIndirect _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(CompilerIrInstr.CallIndirectC _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload.Payload base _ args _)
          (compiler-live-value-vars-into
            (compiler-live-call-args-vars args)
            base)])]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload
            base
            func
            args
            _)
          (compiler-live-value-vars-into
            (compiler-live-value-vars-into
              (compiler-live-call-args-vars args)
              base)
            func)])]
    [(CompilerIrInstr.SpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload.Payload _ _ _ active-mask args _)
          (compiler-live-value-vars-into
            (compiler-live-spmd-call-args-vars args)
            active-mask)])]
    [(CompilerIrInstr.TailCall _ args _) (compiler-live-call-args-vars args)]
    [(CompilerIrInstr.Store _ value _) (compiler-live-value-vars value)]
    [(CompilerIrInstr.Branch cond _ _) (compiler-live-value-vars cond)]
    [(CompilerIrInstr.Return value) (compiler-live-maybe-value-vars value)]
    [(CompilerIrInstr.Phi _ inputs _) (compiler-live-phi-input-vars inputs)]
    [(CompilerIrInstr.Pack _ words _) (compiler-live-value-list-vars words)]
    [(CompilerIrInstr.Word _ src _ _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.Jump _) (compiler-live-set-empty)]
    [(CompilerIrInstr.TailCallIndirect func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(CompilerIrInstr.Switch index _ _ _) (compiler-live-value-vars index)]))

(define (compiler-live-instr-defs [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(CompilerIrInstr.Mov dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Alloc dst _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.AddrOf dst _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Gep dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Load dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Cast dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Bitcast dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.BinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.UnOp dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.LaneId dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Splat dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(CompilerIrInstr.VectorReduce dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(CompilerIrInstr.MaskBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.MaskNot dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.MaskReduce dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(CompilerIrInstr.VectorLoad dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload dst _ _ _ _ _)
          (compiler-live-set1 dst)])]
    [(CompilerIrInstr.TailMask dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.EntryArgc dst) (compiler-live-set1 dst)]
    [(CompilerIrInstr.EntryArgv dst) (compiler-live-set1 dst)]
    [(CompilerIrInstr.EntryEnvp dst) (compiler-live-set1 dst)]
    [(CompilerIrInstr.CpuId dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Xgetbv dst _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Syscall dst _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Call dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.CallIndirect dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.CallIndirectC dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.SpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload.Payload _ _ _ _ _ result)
          (compiler-live-spmd-call-result-defs result)])]
    [(CompilerIrInstr.Phi dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Pack dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Word dst _ _ _) (compiler-live-set1 dst)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-block-use-def-instrs
  [instrs : CompilerIrInstrList]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(CompilerIrInstrList.Nil) (CompilerLiveUseDef.Def uses defs)]
    [(CompilerIrInstrList.Cons instr rest)
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
    (CompilerLiveUseDef.Def uses defs)
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
    [(CompilerIrInstrList.Nil) CompilerLiveMaybeInstr.No]
    [(CompilerIrInstrList.Cons instr rest)
      (match (box-get rest)
        [(CompilerIrInstrList.Nil) (CompilerLiveMaybeInstr.Some instr)]
        [_ (compiler-live-instr-list-last (box-get rest))])]))

(define (compiler-live-instr-seq-last [instrs : CompilerIrInstrSeq]) : CompilerLiveMaybeInstr
  (if (compiler-ir-instr-seq-empty? instrs)
    CompilerLiveMaybeInstr.No
    (CompilerLiveMaybeInstr.Some
      (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1)))))

(define (compiler-live-block-successors [block : CompilerIrBlock]) : CompilerLiveLabelSet
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-live-instr-seq-last instrs)
        [(CompilerLiveMaybeInstr.No) CompilerLiveLabelSet.Nil]
        [(CompilerLiveMaybeInstr.Some instr)
          (match instr
            [(CompilerIrInstr.Jump target)
              (CompilerLiveLabelSet.Cons target (box CompilerLiveLabelSet.Nil))]
            [(CompilerIrInstr.Branch _ true-label false-label)
              (compiler-live-label-set-insert
                (CompilerLiveLabelSet.Cons
                  true-label
                  (box CompilerLiveLabelSet.Nil))
                false-label)]
            [(CompilerIrInstr.Switch _ _ cases default-label)
              (compiler-live-switch-case-successors
                (CompilerLiveLabelSet.Cons
                  default-label
                  (box CompilerLiveLabelSet.Nil))
                cases)]
            [_ CompilerLiveLabelSet.Nil])])]))

(define (compiler-live-build-block [block : CompilerIrBlock]) : CompilerLiveBlock
  (match block
    [(CompilerIrBlock.Block label instrs)
      (match (compiler-live-block-use-def-seq instrs)
        [(CompilerLiveUseDef.Def uses defs)
          (CompilerLiveBlock.Block
            label
            uses
            defs
            (compiler-live-set-empty)
            (compiler-live-set-empty)
            (compiler-live-block-successors block)
            (compiler-live-instr-set-vec-empty))])]))

(define (compiler-live-build-blocks [blocks : CompilerIrBlockList]) : CompilerLiveBlockList
  (match blocks
    [(CompilerIrBlockList.Nil) CompilerLiveBlockList.Nil]
    [(CompilerIrBlockList.Cons block rest)
      (compiler-live-block-cons
        (compiler-live-build-block block)
        (compiler-live-build-blocks (box-get rest)))]
    [(CompilerIrBlockList.Array seq)
      (let
        [i : i64 (- (compiler-ir-block-seq-count seq) 1)]
        [out : CompilerLiveBlockList CompilerLiveBlockList.Nil]
        (begin
          (while (>= i 0)
            (begin
              (set!
                out
                (compiler-live-block-cons
                  (compiler-live-build-block (compiler-ir-block-seq-ref seq i))
                  out))
              (set! i (- i 1))))
          out))]))

(define (compiler-live-block-count [blocks : CompilerLiveBlockList]) : i64
  (match blocks
    [(CompilerLiveBlockList.Nil) 0]
    [(CompilerLiveBlockList.Cons _ rest)
      (+ 1 (compiler-live-block-count (box-get rest)))]))

(define (compiler-live-label-id-map-get
  [ids : (& ids live_label_map.Map)]
  [label : String]) : i64
  (match (live_label_map.get-borrowed ids (& label))
    [(live_label_map.LookupFound slot) slot]
    [(live_label_map.LookupMissing) -1]))

(define (compiler-live-block-graph-fill!
  [blocks : CompilerLiveBlockList]
  [ids : (&mut ids live_label_map.Map)]
  [values : (Array CompilerLiveBlock)]
  [index : i64]) : unit
  (match blocks
    [(CompilerLiveBlockList.Nil) unit]
    [(CompilerLiveBlockList.Cons block rest)
      (match block
        [(CompilerLiveBlock.Block label _ _ _ _ _ _)
          (begin
            (array-set! values index block)
            (if (live_label_map.insert-if-absent? ids label index)
              (compiler-live-block-graph-fill!
                (box-get rest)
                ids
                values
                (+ index 1))
              (io.panic "liveness: duplicate block label")))])]))

(define (compiler-live-block-graph-build [blocks : CompilerLiveBlockList]) : CompilerLiveBlockGraph
  (let
    [count : i64 (compiler-live-block-count blocks)]
    [values : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
    [successors : (Array CompilerLiveIndexVec)
      (make-array CompilerLiveIndexVec count)]
    [ids : live_label_map.Map (live_label_map.with-capacity (+ (* count 2) 1))]
    (begin
      (compiler-live-block-graph-fill! blocks (&mut ids) values 0)
      (compiler-live-block-graph-fill-successors! blocks (& ids) successors 0)
      (CompilerLiveBlockGraph ids values successors))))

(define (compiler-live-i64-array-prefix-copy
  [items : (Array i64)]
  [count : i64]) : (Array i64)
  (if (= count (array-length items))
    items
    (let
      [out : (Array i64) (make-array i64 count)]
      [i : i64 0]
      (begin
        (while (< i count)
          (begin
            (array-set! out i (array-ref items i))
            (set! i (+ i 1))))
        out))))

(define (compiler-live-label-set-fill-indexes!
  [labels : CompilerLiveLabelSet]
  [ids : (& ids live_label_map.Map)]
  [items : (Array i64)]
  [index : i64]) : i64
  (match labels
    [(CompilerLiveLabelSet.Nil) index]
    [(CompilerLiveLabelSet.Cons label rest)
      (let
        [slot : i64 (compiler-live-label-id-map-get ids label)]
        (if (>= slot 0)
          (begin
            (array-set! items index slot)
            (compiler-live-label-set-fill-indexes!
              (box-get rest)
              ids
              items
              (+ index 1)))
          (compiler-live-label-set-fill-indexes! (box-get rest) ids items index)))]))

(define (compiler-live-label-set-to-index-vec
  [labels : CompilerLiveLabelSet]
  [ids : (& ids live_label_map.Map)]) : CompilerLiveIndexVec
  (let
    [items : (Array i64)
      (make-array i64 (compiler-live-label-set-count labels))]
    [count : i64 (compiler-live-label-set-fill-indexes! labels ids items 0)]
    (CompilerLiveIndexVec (compiler-live-i64-array-prefix-copy items count))))

(define (compiler-live-block-graph-fill-successors!
  [blocks : CompilerLiveBlockList]
  [ids : (& ids live_label_map.Map)]
  [successors : (Array CompilerLiveIndexVec)]
  [index : i64]) : unit
  (match blocks
    [(CompilerLiveBlockList.Nil) unit]
    [(CompilerLiveBlockList.Cons block rest)
      (match block
        [(CompilerLiveBlock.Block _ _ _ _ _ block-successors _)
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
  (let
    [slot : i64
      (compiler-live-label-id-map-get (& (struct-get graph ids)) label)]
    (if (>= slot 0)
      (CompilerLiveMaybeBlock.Some (array-ref (struct-get graph blocks) slot))
      CompilerLiveMaybeBlock.No)))

(define (compiler-live-successor-live-out-graph-loop
  [items : (Array i64)]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [acc : CompilerLiveI64Set]) : CompilerLiveI64Set
  (if (>= index (array-length items))
    acc
    (match (array-ref (struct-get graph blocks) (array-ref items index))
      [(CompilerLiveBlock.Block _ _ _ live-in _ _ _)
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
    [(CompilerLiveBlock.Block label uses defs _ _ successors instr-after)
      (let
        [live-out : CompilerLiveI64Set
          (compiler-live-successor-live-out-graph
            (array-ref (struct-get graph successors) index)
            graph)]
        [live-in : CompilerLiveI64Set
          (compiler-live-set-union uses (compiler-live-set-minus live-out defs))]
        (CompilerLiveBlock.Block
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
    [(CompilerLiveBlock.Block _ _ _ left-in left-out _ _)
      (match right
        [(CompilerLiveBlock.Block _ _ _ right-in right-out _ _)
          (and
            (compiler-live-set-eq? left-in right-in)
            (compiler-live-set-eq? left-out right-out))])]))

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
    (CompilerLiveInstrScan.Scan (CompilerLiveInstrSetVec items) live-before)))

(define (compiler-live-fill-instr-after-block
  [ir-block : CompilerIrBlock]
  [block : CompilerLiveBlock]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock.Block label uses defs live-in live-out successors _)
      (match ir-block
        [(CompilerIrBlock.Block _ instrs)
          (match (compiler-live-instr-seq-scan instrs live-out)
            [(CompilerLiveInstrScan.Scan instr-after _)
              (CompilerLiveBlock.Block
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
    [(CompilerIrBlockList.Nil) unit]
    [(CompilerIrBlockList.Cons ir-block rest)
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
    [(CompilerIrBlockList.Array seq)
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
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (let
        [seq : CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
        [block-array : (Array CompilerLiveBlock)
          (compiler-live-build-block-array seq)]
        [graph : CompilerLiveBlockGraph
          (compiler-live-fixpoint-from-array block-array)]
        (begin
          (compiler-live-fill-instr-after-graph-seq!
            seq
            (struct-get graph blocks))
          (CompilerFunctionLiveness.Liveness
            (struct-get graph ids)
            (struct-get graph blocks))))]))

;; ---------------------------------------------------------------------------
;; Edge-precise (SSA) phi liveness -- used ONLY to build the coalescer's
;; interference index (NOT allocation, NOT the backend).
;;
;; The baseline liveness above treats a phi `P = phi[(V_i, B_i)]` as USING every
;; input V_i AT THE PHI BLOCK (compiler-live-instr-uses returns all inputs). That
;; is sound (conservative) but over-approximate: it makes a back-edge / merge
;; input appear live-in to the phi block from EVERY predecessor, leaking the input
;; backward through edges it never travels and around the loop. The result is a
;; loop-carried phi value whose live segments SPURIOUSLY overlap the carry's own
;; segments (e.g. an increment value live at points BEFORE its own definition), so
;; the interference-gated coalescer refuses to join the carry into one interval.
;;
;; Edge-precise liveness instead attributes each phi input to its OWN predecessor
;; edge (LLVM PHIElimination semantics: the input is a COPY at the end of the
;; predecessor): phi inputs are NOT uses at the phi block, and each input V_i is
;; added to the live-out of its predecessor B_i. This removes the spurious overlap
;; while staying SOUND (it is the exact SSA interference). It is used only to admit
;; coalesces the conservative test wrongly rejected; allocation/eviction keep the
;; conservative index, so an error here cannot under-approximate allocation
;; interference -- only mis-coalesce, which the self-host fixpoint catches.
;; ---------------------------------------------------------------------------
(define (compiler-live-instr-uses-nophi [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(CompilerIrInstr.Phi _ _ _) (compiler-live-set-empty)]
    [_ (compiler-live-instr-uses instr)]))

(define (compiler-live-block-use-def-nophi-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (CompilerLiveUseDef.Def uses defs)
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      [instr-uses : CompilerLiveI64Set (compiler-live-instr-uses-nophi instr)]
      [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
      (compiler-live-block-use-def-nophi-seq-from
        instrs
        (+ index 1)
        (compiler-live-set-union uses (compiler-live-set-minus instr-uses defs))
        (compiler-live-set-union defs instr-defs)))))

(define (compiler-live-build-block-nophi [block : CompilerIrBlock]) : CompilerLiveBlock
  (match block
    [(CompilerIrBlock.Block label instrs)
      (match (compiler-live-block-use-def-nophi-seq-from
        instrs
        0
        (compiler-live-set-empty)
        (compiler-live-set-empty))
        [(CompilerLiveUseDef.Def uses defs)
          (CompilerLiveBlock.Block
            label
            uses
            defs
            (compiler-live-set-empty)
            (compiler-live-set-empty)
            (compiler-live-block-successors block)
            (compiler-live-instr-set-vec-empty))])]))

(define (compiler-live-build-blocks-nophi [blocks : CompilerIrBlockList]) : CompilerLiveBlockList
  (match blocks
    [(CompilerIrBlockList.Nil) CompilerLiveBlockList.Nil]
    [(CompilerIrBlockList.Cons block rest)
      (compiler-live-block-cons
        (compiler-live-build-block-nophi block)
        (compiler-live-build-blocks-nophi (box-get rest)))]
    [(CompilerIrBlockList.Array seq)
      (let
        [i : i64 (- (compiler-ir-block-seq-count seq) 1)]
        [out : CompilerLiveBlockList CompilerLiveBlockList.Nil]
        (begin
          (while (>= i 0)
            (begin
              (set!
                out
                (compiler-live-block-cons
                  (compiler-live-build-block-nophi
                    (compiler-ir-block-seq-ref seq i))
                  out))
              (set! i (- i 1))))
          out))]))

;; Accumulate every phi input (V, predLabel) of one phi into phi-out[ids[predLabel]].
(define (compiler-live-phi-out-add-inputs!
  [inputs : CompilerIrPhiInputList]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (Array CompilerLiveI64Set)]) : unit
  (match (compiler-ir-phi-input-list-force-cons inputs)
    [(CompilerIrPhiInputList.Nil) unit]
    [(CompilerIrPhiInputList.Array seq)
      (compiler-live-phi-out-add-inputs!
        (compiler-ir-phi-input-seq-to-list seq)
        ids
        phi-out)]
    [(CompilerIrPhiInputList.Cons value label rest)
      (begin
        (match value
          [(CompilerIrValue.Var v)
            (let
              [slot : i64 (compiler-live-label-id-map-get ids label)]
              (if (>= slot 0)
                (if (and (>= slot 0) (< slot (array-length phi-out)))
                  (array-set!
                    phi-out
                    slot
                    (compiler-live-set-insert (array-ref phi-out slot) v))
                  unit)
                unit))]
          [_ unit])
        (compiler-live-phi-out-add-inputs! (box-get rest) ids phi-out))]))

(define (compiler-live-phi-out-add-seq!
  [instrs : CompilerIrInstrSeq]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (Array CompilerLiveI64Set)]) : unit
  (let
    [count : i64 (compiler-ir-instr-seq-count instrs)]
    [i : i64 0]
    (while (< i count)
      (begin
        (match (compiler-ir-instr-seq-ref instrs i)
          [(CompilerIrInstr.Phi _ inputs _)
            (compiler-live-phi-out-add-inputs! inputs ids phi-out)]
          [_ unit])
        (set! i (+ i 1))))))

(define (compiler-live-phi-out-build!
  [blocks : CompilerIrBlockList]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (Array CompilerLiveI64Set)]) : unit
  (match blocks
    [(CompilerIrBlockList.Nil) unit]
    [(CompilerIrBlockList.Cons block rest)
      (begin
        (match block
          [(CompilerIrBlock.Block _ instrs)
            (compiler-live-phi-out-add-seq! instrs ids phi-out)])
        (compiler-live-phi-out-build! (box-get rest) ids phi-out))]
    [(CompilerIrBlockList.Array seq)
      (let
        [i : i64 0]
        [count : i64 (compiler-ir-block-seq-count seq)]
        (while (< i count)
          (begin
            (match (compiler-ir-block-seq-ref seq i)
              [(CompilerIrBlock.Block _ instrs)
                (compiler-live-phi-out-add-seq! instrs ids phi-out)])
            (set! i (+ i 1)))))]))

(define (compiler-live-recompute-block-graph-ep
  [block : CompilerLiveBlock]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [phi-out : (Array CompilerLiveI64Set)]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock.Block label uses defs _ _ successors instr-after)
      (let
        [succ-out : CompilerLiveI64Set
          (compiler-live-successor-live-out-graph
            (array-ref (struct-get graph successors) index)
            graph)]
        [live-out : CompilerLiveI64Set
          (if (and (>= index 0) (< index (array-length phi-out)))
            (compiler-live-set-union succ-out (array-ref phi-out index))
            succ-out)]
        [live-in : CompilerLiveI64Set
          (compiler-live-set-union uses (compiler-live-set-minus live-out defs))]
        (CompilerLiveBlock.Block
          label
          uses
          defs
          live-in
          live-out
          successors
          instr-after))]))

(define (compiler-live-graph-update-ep!
  [graph : CompilerLiveBlockGraph]
  [phi-out : (Array CompilerLiveI64Set)]) : bool
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
            (compiler-live-recompute-block-graph-ep block graph index phi-out)]
          (begin
            (if (compiler-live-block-liveness-eq? block updated)
              unit
              (begin
                (array-set! blocks index updated)
                (set! changed true)))
            (set! index (- index 1)))))
      changed)))

(define (compiler-live-fixpoint-ep
  [graph : CompilerLiveBlockGraph]
  [phi-out : (Array CompilerLiveI64Set)]) : CompilerLiveBlockGraph
  (let
    [done : bool false]
    (begin
      (while (not done)
        (set! done (not (compiler-live-graph-update-ep! graph phi-out))))
      graph)))

(define (compiler-live-before-instr-nophi
  [live-after : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (compiler-live-set-union
    (compiler-live-instr-uses-nophi instr)
    (compiler-live-set-minus live-after (compiler-live-instr-defs instr))))

(define (compiler-live-instr-seq-scan-nophi-from
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
        (compiler-live-instr-seq-scan-nophi-from
          instrs
          (- index 1)
          (compiler-live-before-instr-nophi live-after instr)
          out)))))

(define (compiler-live-fill-instr-after-block-ep
  [ir-block : CompilerIrBlock]
  [block : CompilerLiveBlock]) : CompilerLiveBlock
  (match block
    [(CompilerLiveBlock.Block label uses defs live-in live-out successors _)
      (match ir-block
        [(CompilerIrBlock.Block _ instrs)
          (let
            [count : i64 (compiler-ir-instr-seq-count instrs)]
            [items : (Array CompilerLiveI64Set)
              (make-array CompilerLiveI64Set count)]
            (begin
              (compiler-live-instr-seq-scan-nophi-from
                instrs
                (- count 1)
                live-out
                items)
              (CompilerLiveBlock.Block
                label
                uses
                defs
                live-in
                live-out
                successors
                (CompilerLiveInstrSetVec items))))])]))

(define (compiler-live-fill-instr-after-graph-ep-cons!
  [ir-blocks : CompilerIrBlockList]
  [blocks : (Array CompilerLiveBlock)]
  [index : i64]) : unit
  (match ir-blocks
    [(CompilerIrBlockList.Nil) unit]
    [(CompilerIrBlockList.Cons ir-block rest)
      (if (>= index (array-length blocks))
        unit
        (begin
          (array-set!
            blocks
            index
            (compiler-live-fill-instr-after-block-ep
              ir-block
              (array-ref blocks index)))
          (compiler-live-fill-instr-after-graph-ep-cons!
            (box-get rest)
            blocks
            (+ index 1))))]
    [(CompilerIrBlockList.Array seq)
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
                (compiler-live-fill-instr-after-block-ep
                  (compiler-ir-block-seq-ref seq i)
                  (array-ref blocks slot)))
              (set! i (+ i 1))))))]))

(define (compiler-live-fill-instr-after-graph-ep-seq!
  [ir-blocks : CompilerIrBlockSeq]
  [blocks : (Array CompilerLiveBlock)]) : unit
  (let
    [count : i64
      (compiler-live-set-min
        (compiler-ir-block-seq-count ir-blocks)
        (array-length blocks))]
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set!
          blocks
          i
          (compiler-live-fill-instr-after-block-ep
            (compiler-ir-block-seq-ref ir-blocks i)
            (array-ref blocks i)))
        (set! i (+ i 1))))))

(define (compiler-live-analyze-function-edge-precise
  [func : CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (let
        [seq : CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
        [block-array : (Array CompilerLiveBlock)
          (compiler-live-build-block-array-nophi seq)]
        [graph0 : CompilerLiveBlockGraph
          (compiler-live-block-graph-build-from-array block-array)]
        [phi-out : (Array CompilerLiveI64Set)
          (make-array
            CompilerLiveI64Set
            (array-length (struct-get graph0 blocks)))]
        (begin
          (let
            [i : i64 0]
            [n : i64 (array-length phi-out)]
            (while (< i n)
              (begin
                (array-set! phi-out i (compiler-live-set-empty))
                (set! i (+ i 1)))))
          (compiler-live-phi-out-build-seq!
            seq
            (& (struct-get graph0 ids))
            phi-out)
          (let
            [graph : CompilerLiveBlockGraph
              (compiler-live-fixpoint-ep graph0 phi-out)]
            (begin
              (compiler-live-fill-instr-after-graph-ep-seq!
                seq
                (struct-get graph blocks))
              (CompilerFunctionLiveness.Liveness
                (struct-get graph ids)
                (struct-get graph blocks))))))]))

(define (compiler-live-function-blocks [liveness : CompilerFunctionLiveness]) : CompilerLiveBlockList
  (match liveness
    [(CompilerFunctionLiveness.Liveness _ blocks)
      (compiler-live-graph-to-list-from
        blocks
        (- (array-length blocks) 1)
        CompilerLiveBlockList.Nil)]))

(define (compiler-live-function-block-count
  [liveness : CompilerFunctionLiveness]) : i64
  (match liveness
    [(CompilerFunctionLiveness.Liveness _ blocks) (array-length blocks)]))

(define (compiler-live-function-block-ref
  [liveness : CompilerFunctionLiveness]
  [index : i64]) : CompilerLiveBlock
  (match liveness
    [(CompilerFunctionLiveness.Liveness _ blocks) (array-ref blocks index)]))

(define (compiler-live-function-block-index
  [liveness : CompilerFunctionLiveness]
  [label : String]) : i64
  (match liveness
    [(CompilerFunctionLiveness.Liveness ids _)
      (compiler-live-label-id-map-get (& ids) label)]))

(define (compiler-live-function-find-block
  [liveness : CompilerFunctionLiveness]
  [label : String]) : CompilerLiveMaybeBlock
  (match liveness
    [(CompilerFunctionLiveness.Liveness ids blocks)
      (let
        [index : i64 (compiler-live-label-id-map-get (& ids) label)]
        (if (>= index 0)
          (CompilerLiveMaybeBlock.Some (array-ref blocks index))
          CompilerLiveMaybeBlock.No))]))

(define (compiler-live-block-label [block : CompilerLiveBlock]) : String
  (match block
    [(CompilerLiveBlock.Block label _ _ _ _ _ _) label]))

(define (compiler-live-block-uses [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock.Block _ uses _ _ _ _ _) uses]))

(define (compiler-live-block-defs [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock.Block _ _ defs _ _ _ _) defs]))

(define (compiler-live-block-live-in [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock.Block _ _ _ live-in _ _ _) live-in]))

(define (compiler-live-block-live-out [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (match block
    [(CompilerLiveBlock.Block _ _ _ _ live-out _ _) live-out]))

(define (compiler-live-block-successor-labels [block : CompilerLiveBlock]) : CompilerLiveLabelSet
  (match block
    [(CompilerLiveBlock.Block _ _ _ _ _ successors _) successors]))

(define (compiler-live-block-instr-after [block : CompilerLiveBlock]) : CompilerLiveInstrSetVec
  (match block
    [(CompilerLiveBlock.Block _ _ _ _ _ _ instr-after) instr-after]))

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
    [(CompilerLiveMaybeBlock.Some block)
      (compiler-live-instr-set-vec-nth
        (compiler-live-block-instr-after block)
        index)]
    [(CompilerLiveMaybeBlock.No) (compiler-live-set-empty)]))

(define (compiler-live-i64-ty) : AstType
  (AstType.I64))

(define (compiler-live-straight-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    "straight"
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 1) (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              CompilerIrBinOp.Add
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 2)
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

(define (compiler-live-branch-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    "branch"
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch (CompilerIrValue.Var 0) "then" "else")
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "then"
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            "else"
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (compiler-live-phi-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    "phi"
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch (CompilerIrValue.Var 0) "left" "right")
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "left"
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              1
              (CompilerIrValue.I64 10)
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump "join")
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "right"
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                2
                (CompilerIrValue.I64 20)
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump "join")
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "join"
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  3
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 1)
                    "left"
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 2)
                      "right"
                      CompilerIrPhiInputList.Nil))
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(define (compiler-live-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 10) (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          1
          CompilerIrBinOp.Add
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 11)
          (compiler-live-i64-ty))
        (compiler-ir-instr-cons
          (CompilerIrInstr.UnOp
            2
            CompilerIrUnOp.Neg
            (CompilerIrValue.Var 12)
            (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              3
              "f"
              (CompilerIrCallArgs.Two
                (CompilerIrValue.Var 1)
                (CompilerIrValue.Var 13))
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                "g"
                (CompilerIrValue.Var 14)
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch (CompilerIrValue.Var 15) "a" "b")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    4
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 16)
                      "a"
                      CompilerIrPhiInputList.Nil)
                    (compiler-live-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                    CompilerIrInstrList.Nil)))))))))
    [(CompilerLiveUseDef.Def uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set7 10 11 12 13 14 15 16))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-memory-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (CompilerIrInstr.Alloc 0 (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (CompilerIrInstr.AddrOf 1 0)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            2
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 10)
            (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load
              3
              (CompilerIrValue.Var 2)
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 11)
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Cast
                  4
                  (CompilerIrValue.Var 3)
                  (compiler-live-i64-ty)
                  (AstType.I32))
                CompilerIrInstrList.Nil)))))))
    [(CompilerLiveUseDef.Def uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set2 10 11))
        (compiler-live-set-eq? defs (compiler-live-set5 0 1 2 3 4)))]))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (match (compiler-live-block-use-def
    (compiler-ir-instr-cons
      (CompilerIrInstr.LaneId 0 4 (compiler-live-i64-ty))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Splat
          1
          (CompilerIrValue.Var 10)
          4
          (compiler-live-i64-ty))
        (compiler-ir-instr-cons
          (ir-instr-vector-bin-op
            2
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            4
            (compiler-live-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.TailMask
              3
              (CompilerIrValue.Var 11)
              (CompilerIrValue.Var 12)
              4)
            (compiler-ir-instr-cons
              (ir-instr-predicated-load
                4
                (CompilerIrValue.Var 13)
                (CompilerIrValue.Var 11)
                (CompilerIrValue.Var 3)
                4
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (ir-instr-predicated-store
                  (CompilerIrValue.Var 14)
                  (CompilerIrValue.Var 11)
                  (CompilerIrValue.Var 2)
                  (CompilerIrValue.Var 3)
                  4
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.MaskReduce
                    5
                    (CompilerIrMaskReduceOp.Any)
                    (CompilerIrValue.Var 3)
                    4)
                  CompilerIrInstrList.Nil))))))))
    [(CompilerLiveUseDef.Def uses defs)
      (and
        (compiler-live-set-eq? uses (compiler-live-set5 10 11 12 13 14))
        (compiler-live-set-eq? defs (compiler-live-set6 0 1 2 3 4 5)))]))

(define (compiler-live-straight-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-straight-function))]
    (match (compiler-live-function-find-block liveness "entry")
      [(CompilerLiveMaybeBlock.Some block)
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
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))]
    (match (compiler-live-function-find-block liveness "entry")
      [(CompilerLiveMaybeBlock.Some block)
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
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))]
    (match (compiler-live-function-find-block liveness "join")
      [(CompilerLiveMaybeBlock.Some block)
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
            [(CompilerLiveMaybeBlock.Some left-block)
              (compiler-live-label-set-contains?
                (compiler-live-block-successor-labels left-block)
                "join")]
            [(CompilerLiveMaybeBlock.No) false]))]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-switch-ok?) : bool
  (let
    [cases : CompilerIrSwitchCaseList
      (compiler-ir-switch-case-cons
        4
        "four"
        (compiler-ir-switch-case-cons 5 "five" CompilerIrSwitchCaseList.Nil))]
    [instr : CompilerIrInstr
      (CompilerIrInstr.Switch (CompilerIrValue.Var 9) 4 cases "other")]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons instr CompilerIrInstrList.Nil)]
    [block : CompilerIrBlock (compiler-ir-block "entry" instrs)]
    [successors : CompilerLiveLabelSet (compiler-live-block-successors block)]
    (match (compiler-live-block-use-def instrs)
      [(CompilerLiveUseDef.Def uses defs)
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
    (io.panic "liveness: smoke mismatch")))

;; Dense-array path for liveness analysis.
;; Avoids linked-list allocation overhead in the hot self-compile path.
(define (compiler-live-ir-block-list-to-seq [blocks : CompilerIrBlockList]) : CompilerIrBlockSeq
  (match blocks
    [(CompilerIrBlockList.Array seq) seq]
    [_ (compiler-ir-block-seq-from-list blocks)]))

(define (compiler-live-build-block-array [blocks : CompilerIrBlockSeq]) : (Array
    CompilerLiveBlock)
  (let
    [count : i64 (compiler-ir-block-seq-count blocks)]
    [out : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set!
            out
            i
            (compiler-live-build-block (compiler-ir-block-seq-ref blocks i)))
          (set! i (+ i 1))))
      out)))

(define (compiler-live-build-block-array-nophi [blocks : CompilerIrBlockSeq]) : (Array
    CompilerLiveBlock)
  (let
    [count : i64 (compiler-ir-block-seq-count blocks)]
    [out : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set!
            out
            i
            (compiler-live-build-block-nophi
              (compiler-ir-block-seq-ref blocks i)))
          (set! i (+ i 1))))
      out)))

(define (compiler-live-phi-out-build-seq!
  [blocks : CompilerIrBlockSeq]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (Array CompilerLiveI64Set)]) : unit
  (let
    [count : i64 (compiler-ir-block-seq-count blocks)]
    [i : i64 0]
    (while (< i count)
      (begin
        (match (compiler-ir-block-seq-ref blocks i)
          [(CompilerIrBlock.Block _ instrs)
            (compiler-live-phi-out-add-seq! instrs ids phi-out)])
        (set! i (+ i 1))))))

(define (compiler-live-block-graph-fill-successors-from-array!
  [blocks : (Array CompilerLiveBlock)]
  [ids : (& ids live_label_map.Map)]
  [successors : (Array CompilerLiveIndexVec)]
  [index : i64]) : unit
  (if (>= index (array-length blocks))
    unit
    (match (array-ref blocks index)
      [(CompilerLiveBlock.Block _ _ _ _ _ block-successors _)
        (begin
          (array-set!
            successors
            index
            (compiler-live-label-set-to-index-vec block-successors ids))
          (compiler-live-block-graph-fill-successors-from-array!
            blocks
            ids
            successors
            (+ index 1)))])))

(define (compiler-live-block-graph-build-from-array
  [blocks : (Array CompilerLiveBlock)]) : CompilerLiveBlockGraph
  (let
    [count : i64 (array-length blocks)]
    [successors : (Array CompilerLiveIndexVec)
      (make-array CompilerLiveIndexVec count)]
    [ids : live_label_map.Map (live_label_map.with-capacity (+ (* count 2) 1))]
    [i : i64 0]
    (begin
      (while (< i count)
        (match (array-ref blocks i)
          [(CompilerLiveBlock.Block label _ _ _ _ _ _)
            (let
              [_inserted : bool
                (live_label_map.insert-if-absent? (&mut ids) label i)]
              unit)])
        (set! i (+ i 1)))
      (compiler-live-block-graph-fill-successors-from-array!
        blocks
        (& ids)
        successors
        0)
      (CompilerLiveBlockGraph ids blocks successors))))

(define (compiler-live-fill-instr-after-graph-seq!
  [ir-blocks : CompilerIrBlockSeq]
  [blocks : (Array CompilerLiveBlock)]) : unit
  (let
    [count : i64
      (compiler-live-set-min
        (compiler-ir-block-seq-count ir-blocks)
        (array-length blocks))]
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set!
          blocks
          i
          (compiler-live-fill-instr-after-block
            (compiler-ir-block-seq-ref ir-blocks i)
            (array-ref blocks i)))
        (set! i (+ i 1))))))

(define (compiler-live-fixpoint-from-array [blocks : (Array CompilerLiveBlock)]) : CompilerLiveBlockGraph
  (let
    [graph : CompilerLiveBlockGraph
      (compiler-live-block-graph-build-from-array blocks)]
    [done : bool false]
    (begin
      (while (not done)
        (set! done (not (compiler-live-graph-update! graph))))
      graph)))