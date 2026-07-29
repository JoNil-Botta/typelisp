;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis.
;;
;; This module keeps the selfhost liveness pass deterministic while storing
;; integer live sets as compact bitsets keyed by dense IR variable ids. Do not
;; replace CompilerLiveI64Set with the general `(set i64)` family without a
;; compiler-path benchmark: opt2 self-compile is sensitive to liveness set
;; iteration and copy costs.
(import stdlib.io)
(import "compiler_ir_types.tl")
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as live_label_map)

(defstruct CompilerLiveI64Set
  (words (Array i64)))

(defenum CompilerLiveLabelSet
  (Nil)
  ;; Successor labels in deterministic head-first order. The logical head is
  ;; the end of the dense prefix, which makes tail views allocation-free.
  (Dense (Array i64) i64))

(define (compiler-live-label-set-ref [set : CompilerLiveLabelSet] [index : i64]) : i64
  (match set
    [(CompilerLiveLabelSet.Nil) -1]
    [(CompilerLiveLabelSet.Dense items len)
      (array-ref items (- (- len 1) index))]))

(define (compiler-live-label-set-tail [set : CompilerLiveLabelSet]) : CompilerLiveLabelSet
  (match set
    [(CompilerLiveLabelSet.Nil) CompilerLiveLabelSet.Nil]
    [(CompilerLiveLabelSet.Dense items len)
      (if (<= len 1)
        CompilerLiveLabelSet.Nil
        (CompilerLiveLabelSet.Dense items (- len 1)))]))

(define (compiler-live-label-set-cons
  [value : i64]
  [set : CompilerLiveLabelSet]) : CompilerLiveLabelSet
  (match set
    [(CompilerLiveLabelSet.Nil)
      (let
        [items : (Array i64) (make-array i64 4)]
        (begin
          (array-set! items 0 value)
          (CompilerLiveLabelSet.Dense items 1)))]
    [(CompilerLiveLabelSet.Dense items len)
      (if (< len (array-length items))
        (begin
          (array-set! items len value)
          (CompilerLiveLabelSet.Dense items (+ len 1)))
        (let
          [capacity : i64
            (if (< len 4)
              4
              (* len 2))]
          [bigger : (Array i64) (make-array i64 capacity)]
          [index : i64 0]
          (begin
            (while (< index len)
              (begin
                (array-set! bigger index (array-ref items index))
                (set! index (+ index 1))))
            (array-set! bigger len value)
            (CompilerLiveLabelSet.Dense bigger (+ len 1)))))]))

(defstruct CompilerLiveIndexVec
  (items (Array i64)))

(defstruct CompilerLiveInstrSetVec
  (items (Array CompilerLiveI64Set)))

(defstruct CompilerLiveBlock
  (label i64)
  (uses CompilerLiveI64Set)
  (defs CompilerLiveI64Set)
  (live-in CompilerLiveI64Set)
  (live-out CompilerLiveI64Set)
  (successors CompilerLiveLabelSet)
  (instr-after CompilerLiveInstrSetVec))

(defstruct CompilerLiveBlockGraph
  (ids live_label_map.Map)
  (blocks (Array CompilerLiveBlock))
  (successors (Array CompilerLiveIndexVec))
  (predecessors (Array CompilerLiveIndexVec)))

(defstruct CompilerLiveFunctionGraphBuild
  (seq CompilerIrBlockSeq)
  (graph CompilerLiveBlockGraph))

(defenum CompilerFunctionLiveness
  (Liveness live_label_map.Map (Array CompilerLiveBlock)))

(defenum CompilerLiveMaybeBlock
  (No)
  (Some CompilerLiveBlock))

(defenum CompilerLiveMaybeInstr
  (No)
  (Some CompilerIrInstr))

(defstruct CompilerLiveUseDef
  (uses CompilerLiveI64Set)
  (defs CompilerLiveI64Set))

(define (compiler-live-instr-set-vec-empty) : CompilerLiveInstrSetVec
  (CompilerLiveInstrSetVec (make-array CompilerLiveI64Set 0)))

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

;; Every empty set is the same value: the word array has length zero, so no
;; index is in range and nothing can ever be written into it. Handing out one
;; shared instance is therefore indistinguishable from allocating a fresh one,
;; and it removes an allocation from a function called throughout liveness --
;; call-edge attribution puts 318,627,090 Ir of `tl_alloc` behind this one
;; caller in an opt2 self-compile.
(define compiler-live-set-empty-value : CompilerLiveI64Set
  (CompilerLiveI64Set (make-array i64 0)))

(define (compiler-live-set-empty) : CompilerLiveI64Set
  compiler-live-set-empty-value)

(define (compiler-live-set-word-count [set : CompilerLiveI64Set]) : i64
  (array-length (compiler-live-set-words set)))

(define (compiler-live-set-word-at
  [set : CompilerLiveI64Set]
  [word-index : i64]) : i64
  (let
    [words : (Array i64) (compiler-live-set-words set)]
    (if (and (>= word-index 0) (< word-index (array-length words)))
      (unsafe
        (ptr-read (ptr-offset (array-data words) word-index)))
      0)))

;; Callers must prove `0 <= word-index < compiler-live-set-word-count set`.
(define (compiler-live-set-word-at-bounded
  [set : CompilerLiveI64Set]
  [word-index : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-offset (array-data (compiler-live-set-words set)) word-index))))

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
                (compiler-live-set-word-at-bounded a i)
                (compiler-live-set-word-at-bounded b i))
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
          [old-bits : i64 (compiler-live-set-word-at-bounded set word-index)]
          (if (= (bit-and old-bits mask) 0)
            set
            (let
              [out : (Array i64)
                (compiler-live-set-copy-with-capacity set capacity)]
              (begin
                (array-set! out word-index (bit-and old-bits (bit-xor mask -1)))
                (compiler-live-set-from-words-trimmed out capacity)))))))))

(define (compiler-live-set-union
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [left-words : (Array i64) (compiler-live-set-words left)]
    [right-words : (Array i64) (compiler-live-set-words right)]
    [left-count : i64 (array-length left-words)]
    [right-count : i64 (array-length right-words)]
    (if (= right-count 0)
      left
      (if (= left-count 0)
        right
        (let
          ;; Both inputs are trimmed, so a longer right operand necessarily
          ;; contributes a set bit. Otherwise scan only until the first bit
          ;; missing from left. Fixpoint iterations commonly find no change;
          ;; avoid allocating and filling a throwaway immutable copy for them.
          [probe : i64 0]
          [changed : bool (> right-count left-count)]
          (begin
            (while (and (not changed) (< probe right-count))
              (let
                [left-bits : i64
                  (unsafe
                    (ptr-read (ptr-offset (array-data left-words) probe)))]
                [right-bits : i64
                  (unsafe
                    (ptr-read (ptr-offset (array-data right-words) probe)))]
                (begin
                  (if (not (= (bit-and right-bits (bit-xor left-bits -1)) 0))
                    (set! changed true)
                    unit)
                  (set! probe (+ probe 1)))))
            (if changed
              (let
                [count : i64
                  (if (< left-count right-count)
                    right-count
                    left-count)]
                [common-count : i64
                  (if (< left-count right-count)
                    left-count
                    right-count)]
                [out : (Array i64) (make-array i64 count)]
                [left-data : (MutPtr i64)
                  (unsafe
                    (array-data left-words))]
                [right-data : (MutPtr i64)
                  (unsafe
                    (array-data right-words))]
                [out-data : (MutPtr i64)
                  (unsafe
                    (ptr-cast (array-data out) : (MutPtr i64)))]
                [index : i64 0]
                (begin
                  ;; The loop bounds prove every raw access. Split the common
                  ;; prefix from the longer operand's tail so the hot loop has
                  ;; no per-word length branches or destination bounds checks.
                  (while (< index common-count)
                    (begin
                      (unsafe
                        (ptr-write!
                          (ptr-offset out-data index)
                          (bit-or
                            (ptr-read (ptr-offset left-data index))
                            (ptr-read (ptr-offset right-data index)))))
                      (set! index (+ index 1))))
                  (if (< left-count right-count)
                    (while (< index count)
                      (begin
                        (unsafe
                          (ptr-write!
                            (ptr-offset out-data index)
                            (ptr-read (ptr-offset right-data index))))
                        (set! index (+ index 1))))
                    (while (< index count)
                      (begin
                        (unsafe
                          (ptr-write!
                            (ptr-offset out-data index)
                            (ptr-read (ptr-offset left-data index))))
                        (set! index (+ index 1)))))
                  ;; The longer input's final word is nonzero because every
                  ;; CompilerLiveI64Set is canonical, so union cannot introduce
                  ;; a trailing zero word.
                  (CompilerLiveI64Set out)))
              left)))))))

(define (compiler-live-set-minus
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [left-words : (Array i64) (compiler-live-set-words left)]
    [right-words : (Array i64) (compiler-live-set-words right)]
    [count : i64 (array-length left-words)]
    [right-count : i64 (array-length right-words)]
    [probe-count : i64 (compiler-live-set-min count right-count)]
    [probe : i64 0]
    [changed : bool false]
    (begin
      ;; Prove the sets intersect before allocating the immutable result.
      (while (and (not changed) (< probe probe-count))
        (let
          [left-bits : i64
            (unsafe
              (ptr-read (ptr-offset (array-data left-words) probe)))]
          [right-bits : i64
            (unsafe
              (ptr-read (ptr-offset (array-data right-words) probe)))]
          (begin
            (if (not (= (bit-and left-bits right-bits) 0))
              (set! changed true)
              unit)
            (set! probe (+ probe 1)))))
      (if changed
        (let
          [out : (Array i64) (make-array i64 count)]
          [index : i64 0]
          (begin
            (while (< index count)
              (let
                [left-bits : i64
                  (unsafe
                    (ptr-read (ptr-offset (array-data left-words) index)))]
                [right-bits : i64
                  (if (< index right-count)
                    (unsafe
                      (ptr-read (ptr-offset (array-data right-words) index)))
                    0)]
                (begin
                  (array-set!
                    out
                    index
                    (bit-and left-bits (bit-xor right-bits -1)))
                  (set! index (+ index 1)))))
            (compiler-live-set-from-words-trimmed out count)))
        left))))

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

;; Mutable liveness scratch keeps the changing dataflow facts in one
;; function-sized word row. CompilerLiveI64Set remains the canonical stored
;; representation: scratch is copied and trimmed only when a block fact or
;; instruction point must outlive the current walk.
(define (compiler-live-scratch-clear! [words : (Array i64)]) : unit
  (let
    [data : (MutPtr i64)
      (unsafe
        (array-data words))]
    [count : i64 (array-length words)]
    [index : i64 0]
    (while (< index count)
      (begin
        (unsafe
          (ptr-write! (ptr-offset data index) 0))
        (set! index (+ index 1))))))

(define (compiler-live-scratch-copy-set!
  [words : (Array i64)]
  [set : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [src-words : (Array i64) (compiler-live-set-words set)]
    [src : (MutPtr i64)
      (unsafe
        (array-data src-words))]
    [src-count : i64 (array-length src-words)]
    [count : i64 (array-length words)]
    [index : i64 0]
    (begin
      (while (< index src-count)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst index)
              (ptr-read (ptr-offset src index))))
          (set! index (+ index 1))))
      (while (< index count)
        (begin
          (unsafe
            (ptr-write! (ptr-offset dst index) 0))
          (set! index (+ index 1))))
      src-count)))

(define (compiler-live-scratch-union-set!
  [words : (Array i64)]
  [active-count : i64]
  [set : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [src-words : (Array i64) (compiler-live-set-words set)]
    [src : (MutPtr i64)
      (unsafe
        (array-data src-words))]
    [count : i64 (array-length src-words)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst index)
              (bit-or
                (ptr-read (ptr-offset dst index))
                (ptr-read (ptr-offset src index)))))
          (set! index (+ index 1))))
      (compiler-live-set-max active-count count))))

(define (compiler-live-scratch-step!
  [words : (Array i64)]
  [active-count : i64]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [use-words : (Array i64) (compiler-live-set-words uses)]
    [def-words : (Array i64) (compiler-live-set-words defs)]
    [use-data : (MutPtr i64)
      (unsafe
        (array-data use-words))]
    [def-data : (MutPtr i64)
      (unsafe
        (array-data def-words))]
    [use-count : i64 (array-length use-words)]
    [def-count : i64 (array-length def-words)]
    [count : i64
      (compiler-live-set-max
        active-count
        (compiler-live-set-max use-count def-count))]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [use-bits : i64
            (if (< index use-count)
              (unsafe
                (ptr-read (ptr-offset use-data index)))
              0)]
          [def-bits : i64
            (if (< index def-count)
              (unsafe
                (ptr-read (ptr-offset def-data index)))
              0)]
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset dst index)
                (bit-or
                  (bit-and
                    (ptr-read (ptr-offset dst index))
                    (bit-xor def-bits -1))
                  use-bits)))
            (set! index (+ index 1)))))
      (compiler-live-set-trim-length words count))))

(define (compiler-live-scratch-eq-set?
  [words : (Array i64)]
  [active-count : i64]
  [set : CompilerLiveI64Set]) : bool
  (let
    [set-count : i64 (compiler-live-set-word-count set)]
    [data : (MutPtr i64)
      (unsafe
        (array-data words))]
    [set-words : (Array i64) (compiler-live-set-words set)]
    [set-data : (MutPtr i64)
      (unsafe
        (array-data set-words))]
    [index : i64 0]
    [same : bool (= active-count set-count)]
    (begin
      (while (and same (< index active-count))
        (begin
          (if (=
            (unsafe
              (ptr-read (ptr-offset data index)))
            (unsafe
              (ptr-read (ptr-offset set-data index))))
            unit
            (set! same false))
          (set! index (+ index 1))))
      same)))

(define (compiler-live-scratch-freeze
  [words : (Array i64)]
  [active-count : i64]) : CompilerLiveI64Set
  (let
    [count : i64 (compiler-live-set-trim-length words active-count)]
    (if (<= count 0)
      (compiler-live-set-empty)
      (let
        [out : (Array i64) (make-array i64 count)]
        [src : (MutPtr i64)
          (unsafe
            (array-data words))]
        [dst : (MutPtr i64)
          (unsafe
            (array-data out))]
        [index : i64 0]
        (begin
          (while (< index count)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset dst index)
                  (ptr-read (ptr-offset src index))))
              (set! index (+ index 1))))
          (CompilerLiveI64Set out))))))

(define (compiler-live-var-word-count [vars : i64]) : i64
  (if (<= vars 0)
    0
    (+ (compiler-live-set-word-index (- vars 1)) 1)))

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
                (compiler-live-set-word-at-bounded set index)
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
              (compiler-live-set-word-at-bounded set index)
              (* index (compiler-live-set-word-bits))
              (- (compiler-live-set-word-bits) 1)
              score))
          (set! index (- index 1))))
      score)))

(define (compiler-live-set-builder-insert! [words : (Array i64)] [value : i64]) : unit
  (if (< value 0)
    unit
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [old-bits : i64 (array-ref words word-index)]
      (array-set!
        words
        word-index
        (bit-or old-bits (compiler-live-set-bit-mask value))))))

(define (compiler-live-set-builder [max-value : i64]) : (Array i64)
  (make-array
    i64
    (if (< max-value 0)
      0
      (+ (compiler-live-set-word-index max-value) 1))))

(define (compiler-live-set1 [a : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64) (compiler-live-set-builder a)]
    (begin
      (compiler-live-set-builder-insert! words a)
      (CompilerLiveI64Set words))))

(define (compiler-live-set2 [a : i64] [b : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder (compiler-live-set-max a b))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (CompilerLiveI64Set words))))

(define (compiler-live-set3 [a : i64] [b : i64] [c : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder
        (compiler-live-set-max (compiler-live-set-max a b) c))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (CompilerLiveI64Set words))))

(define (compiler-live-set4 [a : i64] [b : i64] [c : i64] [d : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder
        (compiler-live-set-max
          (compiler-live-set-max a b)
          (compiler-live-set-max c d)))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (compiler-live-set-builder-insert! words d)
      (CompilerLiveI64Set words))))

(define (compiler-live-set5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder
        (compiler-live-set-max
          (compiler-live-set-max (compiler-live-set-max a b) c)
          (compiler-live-set-max d e)))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (compiler-live-set-builder-insert! words d)
      (compiler-live-set-builder-insert! words e)
      (CompilerLiveI64Set words))))

(define (compiler-live-set6
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder
        (compiler-live-set-max
          (compiler-live-set-max (compiler-live-set-max a b) c)
          (compiler-live-set-max (compiler-live-set-max d e) f)))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (compiler-live-set-builder-insert! words d)
      (compiler-live-set-builder-insert! words e)
      (compiler-live-set-builder-insert! words f)
      (CompilerLiveI64Set words))))

(define (compiler-live-set7
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : CompilerLiveI64Set
  (let
    [words : (Array i64)
      (compiler-live-set-builder
        (compiler-live-set-max
          (compiler-live-set-max
            (compiler-live-set-max (compiler-live-set-max a b) c)
            (compiler-live-set-max d e))
          (compiler-live-set-max f g)))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (compiler-live-set-builder-insert! words d)
      (compiler-live-set-builder-insert! words e)
      (compiler-live-set-builder-insert! words f)
      (compiler-live-set-builder-insert! words g)
      (CompilerLiveI64Set words))))

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
    [deduplicated : CompilerLiveI64Set (compiler-live-set4 -1 31 31 66)]
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
      (set!
        ok
        (and ok (compiler-live-set-eq? deduplicated (compiler-live-set2 31 66))))
      ok)))

(define (compiler-live-scratch-ops-ok?) : bool
  (let
    [words : (Array i64) (make-array i64 6)]
    [copy-count : i64
      (compiler-live-scratch-copy-set! words (compiler-live-set3 1 64 130))]
    [copy-ok : bool
      (and
        (= copy-count 5)
        (compiler-live-scratch-eq-set?
          words
          copy-count
          (compiler-live-set3 1 64 130)))]
    [union-count : i64
      (compiler-live-scratch-union-set!
        words
        copy-count
        (compiler-live-set2 65 191))]
    [union-ok : bool
      (and
        (= union-count 6)
        (compiler-live-scratch-eq-set?
          words
          union-count
          (compiler-live-set5 1 64 65 130 191)))]
    [step-count : i64
      (compiler-live-scratch-step!
        words
        union-count
        (compiler-live-set1 0)
        (compiler-live-set2 1 130))]
    [step-ok : bool
      (and
        (= step-count 6)
        (compiler-live-scratch-eq-set?
          words
          step-count
          (compiler-live-set4 0 64 65 191))
        (compiler-live-set-eq?
          (compiler-live-scratch-freeze words step-count)
          (compiler-live-set4 0 64 65 191)))]
    [short-count : i64
      (compiler-live-scratch-copy-set! words (compiler-live-set1 7))]
    [short-ok : bool
      (and
        (= short-count 1)
        (compiler-live-scratch-eq-set? words short-count (compiler-live-set1 7))
        (= (compiler-live-set-trim-length words 6) 1))]
    [_cleared : unit (compiler-live-scratch-clear! words)]
    (and
      copy-ok
      union-ok
      step-ok
      short-ok
      (= (compiler-live-set-trim-length words 6) 0))))

(define (compiler-live-label-set-contains?
  [set : CompilerLiveLabelSet]
  [value : i64]) : bool
  (match set
    [(CompilerLiveLabelSet.Nil) false]
    [(CompilerLiveLabelSet.Dense _ _)
      (if (= (compiler-live-label-set-ref set 0) value)
        true
        (compiler-live-label-set-contains?
          (compiler-live-label-set-tail set)
          value))]))

(define (compiler-live-label-set-insert
  [set : CompilerLiveLabelSet]
  [value : i64]) : CompilerLiveLabelSet
  (if (compiler-live-label-set-contains? set value)
    set
    (compiler-live-label-set-cons value set)))

(define (compiler-live-label-set-count [set : CompilerLiveLabelSet]) : i64
  (match set
    [(CompilerLiveLabelSet.Nil) 0]
    [(CompilerLiveLabelSet.Dense _ len) len]))

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
      (let
        [lhs (struct-get (box-get payload-box) lhs)]
        [rhs (struct-get (box-get payload-box) rhs)]
        (compiler-live-values2-vars lhs rhs))]
    [(CompilerIrInstr.VectorPrefix payload-box)
      (let
        [src (struct-get (box-get payload-box) src)]
        [carry (struct-get (box-get payload-box) carry)]
        (compiler-live-values2-vars src carry))]
    [(CompilerIrInstr.VectorReduce _ _ src _ _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.VectorCompare payload-box)
      (let
        [lhs (struct-get (box-get payload-box) lhs)]
        [rhs (struct-get (box-get payload-box) rhs)]
        (compiler-live-values2-vars lhs rhs))]
    [(CompilerIrInstr.MaskBinOp _ _ lhs rhs _)
      (compiler-live-values2-vars lhs rhs)]
    [(CompilerIrInstr.MaskNot _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.MaskReduce _ _ src _) (compiler-live-value-vars src)]
    [(CompilerIrInstr.Select payload-box)
      (let
        [mask (struct-get (box-get payload-box) mask)]
        [on-true (struct-get (box-get payload-box) on-true)]
        [on-false (struct-get (box-get payload-box) on-false)]
        (compiler-live-values3-vars mask on-true on-false))]
    [(CompilerIrInstr.VectorLoad _ base index _ _)
      (compiler-live-values2-vars base index)]
    [(CompilerIrInstr.VectorStore payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [value (struct-get (box-get payload-box) value)]
        (compiler-live-values3-vars base index value))]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [value (struct-get (box-get payload-box) value)]
        [mask (struct-get (box-get payload-box) mask)]
        (compiler-live-values4-vars base index value mask))]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [mask (struct-get (box-get payload-box) mask)]
        (compiler-live-values3-vars base index mask))]
    [(CompilerIrInstr.GatherLoad payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index-base (struct-get (box-get payload-box) index-base)]
        [index (struct-get (box-get payload-box) index)]
        (compiler-live-values3-vars base index-base index))]
    [(CompilerIrInstr.VectorShuffle payload-box)
      (let
        [source (struct-get (box-get payload-box) source)]
        [selector-low (struct-get (box-get payload-box) selector-low)]
        [selector-high (struct-get (box-get payload-box) selector-high)]
        [active-lanes (struct-get (box-get payload-box) active-lanes)]
        (compiler-live-set-union
          (compiler-live-values3-vars source selector-low active-lanes)
          (compiler-live-maybe-value-vars selector-high)))]
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
      (let
        [base (struct-get (box-get payload-box) base)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into (compiler-live-call-args-vars args) base))]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [func (struct-get (box-get payload-box) callee)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into
          (compiler-live-value-vars-into
            (compiler-live-call-args-vars args)
            base)
          func))]
    [(CompilerIrInstr.SpmdCall payload-box)
      (let
        [active-mask (struct-get (box-get payload-box) active-mask)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into
          (compiler-live-spmd-call-args-vars args)
          active-mask))]
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
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.VectorPrefix payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.VectorReduce dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.VectorCompare payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.MaskBinOp dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.MaskNot dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.MaskReduce dst _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Select payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.VectorLoad dst _ _ _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.GatherLoad payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
    [(CompilerIrInstr.VectorShuffle payload-box)
      (let
        [dst (struct-get (box-get payload-box) dst)]
        (compiler-live-set1 dst))]
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
      (let
        [result (struct-get (box-get payload-box) result)]
        (compiler-live-spmd-call-result-defs result))]
    [(CompilerIrInstr.Phi dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Pack dst _ _) (compiler-live-set1 dst)]
    [(CompilerIrInstr.Word dst _ _ _) (compiler-live-set1 dst)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-block-use-def-instrs
  [instrs : CompilerIrInstrList]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(CompilerIrInstrList.Nil) (CompilerLiveUseDef uses defs)]
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

(define (compiler-live-block-use-def-step!
  [uses : (Array i64)]
  [defs : (Array i64)]
  [instr-uses : CompilerLiveI64Set]
  [instr-defs : CompilerLiveI64Set]) : unit
  (let
    [use-data : (MutPtr i64)
      (unsafe
        (array-data uses))]
    [def-data : (MutPtr i64)
      (unsafe
        (array-data defs))]
    [instr-use-words : (Array i64) (compiler-live-set-words instr-uses)]
    [instr-def-words : (Array i64) (compiler-live-set-words instr-defs)]
    [instr-use-data : (MutPtr i64)
      (unsafe
        (array-data instr-use-words))]
    [instr-def-data : (MutPtr i64)
      (unsafe
        (array-data instr-def-words))]
    [instr-use-count : i64 (array-length instr-use-words)]
    [instr-def-count : i64 (array-length instr-def-words)]
    [count : i64 (compiler-live-set-max instr-use-count instr-def-count)]
    [index : i64 0]
    (while (< index count)
      (let
        [instr-use-bits : i64
          (if (< index instr-use-count)
            (unsafe
              (ptr-read (ptr-offset instr-use-data index)))
            0)]
        [instr-def-bits : i64
          (if (< index instr-def-count)
            (unsafe
              (ptr-read (ptr-offset instr-def-data index)))
            0)]
        [old-def-bits : i64
          (unsafe
            (ptr-read (ptr-offset def-data index)))]
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset use-data index)
              (bit-or
                (ptr-read (ptr-offset use-data index))
                (bit-and instr-use-bits (bit-xor old-def-bits -1)))))
          (unsafe
            (ptr-write!
              (ptr-offset def-data index)
              (bit-or old-def-bits instr-def-bits)))
          (set! index (+ index 1)))))))

(define (compiler-live-block-use-def-seq-with-scratch
  [instrs : CompilerIrInstrSeq]
  [uses : (Array i64)]
  [defs : (Array i64)]
  [edge-precise? : bool]) : CompilerLiveUseDef
  (let
    [count : i64 (compiler-ir-instr-seq-count instrs)]
    [use-count : i64 0]
    [def-count : i64 0]
    [index : i64 0]
    (begin
      (compiler-live-scratch-clear! uses)
      (compiler-live-scratch-clear! defs)
      (while (< index count)
        (let
          [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
          [instr-uses : CompilerLiveI64Set
            (if edge-precise?
              (compiler-live-instr-uses-nophi instr)
              (compiler-live-instr-uses instr))]
          [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
          (begin
            (compiler-live-block-use-def-step! uses defs instr-uses instr-defs)
            (set!
              use-count
              (compiler-live-set-max
                use-count
                (compiler-live-set-word-count instr-uses)))
            (set!
              def-count
              (compiler-live-set-max
                def-count
                (compiler-live-set-word-count instr-defs)))
            (set! index (+ index 1)))))
      (CompilerLiveUseDef
        (compiler-live-scratch-freeze uses use-count)
        (compiler-live-scratch-freeze defs def-count)))))

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
              (compiler-live-label-set-cons target CompilerLiveLabelSet.Nil)]
            [(CompilerIrInstr.Branch _ true-label false-label)
              (compiler-live-label-set-insert
                (compiler-live-label-set-cons
                  true-label
                  CompilerLiveLabelSet.Nil)
                false-label)]
            [(CompilerIrInstr.Switch _ _ cases default-label)
              (compiler-live-switch-case-successors
                (compiler-live-label-set-cons
                  default-label
                  CompilerLiveLabelSet.Nil)
                cases)]
            [_ CompilerLiveLabelSet.Nil])])]))

(define (compiler-live-build-block-from-use-def
  [block : CompilerIrBlock]
  [use-def : CompilerLiveUseDef]) : CompilerLiveBlock
  (match block
    [(CompilerIrBlock.Block label _)
      (CompilerLiveBlock
        label
        (struct-get use-def uses)
        (struct-get use-def defs)
        (compiler-live-set-empty)
        (compiler-live-set-empty)
        (compiler-live-block-successors block)
        (compiler-live-instr-set-vec-empty))]))

(define (compiler-live-label-id-map-get
  [ids : (& ids live_label_map.Map)]
  [label : i64]) : i64
  (match (live_label_map.get-borrowed ids label)
    [(live_label_map.LookupFound slot) slot]
    [(live_label_map.LookupMissing) -1]))

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
    [(CompilerLiveLabelSet.Dense _ _)
      (let
        [label : i64 (compiler-live-label-set-ref labels 0)]
        [slot : i64 (compiler-live-label-id-map-get ids label)]
        (if (>= slot 0)
          (begin
            (array-set! items index slot)
            (compiler-live-label-set-fill-indexes!
              (compiler-live-label-set-tail labels)
              ids
              items
              (+ index 1)))
          (compiler-live-label-set-fill-indexes!
            (compiler-live-label-set-tail labels)
            ids
            items
            index)))]))

(define (compiler-live-label-set-to-index-vec
  [labels : CompilerLiveLabelSet]
  [ids : (& ids live_label_map.Map)]) : CompilerLiveIndexVec
  (let
    [items : (Array i64)
      (make-array i64 (compiler-live-label-set-count labels))]
    [count : i64 (compiler-live-label-set-fill-indexes! labels ids items 0)]
    (CompilerLiveIndexVec (compiler-live-i64-array-prefix-copy items count))))

;; Precompute reverse CFG edges once. The worklist below only reprocesses
;; predecessors of a changed block, preserving deterministic source/RPO order.
(define (compiler-live-predecessor-counts-add!
  [successors : (Array CompilerLiveIndexVec)]
  [counts : (Array i64)]
  [source : i64]) : unit
  (if (>= source (array-length successors))
    unit
    (let
      [items : (Array i64) (struct-get (array-ref successors source) items)]
      [i : i64 0]
      (begin
        (while (< i (array-length items))
          (let
            [target : i64 (array-ref items i)]
            (begin
              (array-set! counts target (+ (array-ref counts target) 1))
              (set! i (+ i 1)))))
        (compiler-live-predecessor-counts-add! successors counts (+ source 1))))))

(define (compiler-live-predecessor-items-make
  [counts : (Array i64)]
  [index : i64]
  [out : (Array CompilerLiveIndexVec)]) : unit
  (if (>= index (array-length counts))
    unit
    (begin
      (array-set!
        out
        index
        (CompilerLiveIndexVec (make-array i64 (array-ref counts index))))
      (compiler-live-predecessor-items-make counts (+ index 1) out))))

(define (compiler-live-predecessor-fill!
  [successors : (Array CompilerLiveIndexVec)]
  [predecessors : (Array CompilerLiveIndexVec)]
  [next : (Array i64)]
  [source : i64]) : unit
  (if (>= source (array-length successors))
    unit
    (let
      [items : (Array i64) (struct-get (array-ref successors source) items)]
      [i : i64 0]
      (begin
        (while (< i (array-length items))
          (let
            [target : i64 (array-ref items i)]
            [slot : i64 (array-ref next target)]
            [target-items : (Array i64)
              (struct-get (array-ref predecessors target) items)]
            (begin
              (array-set! target-items slot source)
              (array-set! next target (+ slot 1))
              (set! i (+ i 1)))))
        (compiler-live-predecessor-fill!
          successors
          predecessors
          next
          (+ source 1))))))

(define (compiler-live-predecessors-build
  [successors : (Array CompilerLiveIndexVec)]) : (Array CompilerLiveIndexVec)
  (let
    [count : i64 (array-length successors)]
    [counts : (Array i64) (make-array i64 count)]
    [out : (Array CompilerLiveIndexVec) (make-array CompilerLiveIndexVec count)]
    [next : (Array i64) (make-array i64 count)]
    (begin
      (compiler-live-predecessor-counts-add! successors counts 0)
      (compiler-live-predecessor-items-make counts 0 out)
      (compiler-live-predecessor-fill! successors out next 0)
      out)))

(define (compiler-live-successor-live-out-graph-into!
  [successors : CompilerLiveIndexVec]
  [graph : CompilerLiveBlockGraph]
  [words : (Array i64)]) : i64
  (let
    [items : (Array i64) (struct-get successors items)]
    [active-count : i64 0]
    [index : i64 0]
    (begin
      (compiler-live-scratch-clear! words)
      (while (< index (array-length items))
        (let
          [successor : CompilerLiveBlock
            (array-ref (struct-get graph blocks) (array-ref items index))]
          (begin
            (set!
              active-count
              (compiler-live-scratch-union-set!
                words
                active-count
                (struct-get successor live-in)))
            (set! index (+ index 1)))))
      active-count)))

(define (compiler-live-recompute-block-graph
  [block : CompilerLiveBlock]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [words : (Array i64)]) : CompilerLiveBlock
  (let
    [live-out-count : i64
      (compiler-live-successor-live-out-graph-into!
        (array-ref (struct-get graph successors) index)
        graph
        words)]
    [live-out : CompilerLiveI64Set
      (if (compiler-live-scratch-eq-set?
        words
        live-out-count
        (struct-get block live-out))
        (struct-get block live-out)
        (compiler-live-scratch-freeze words live-out-count))]
    [live-in-count : i64
      (compiler-live-scratch-step!
        words
        live-out-count
        (struct-get block uses)
        (struct-get block defs))]
    [live-in : CompilerLiveI64Set
      (if (compiler-live-scratch-eq-set?
        words
        live-in-count
        (struct-get block live-in))
        (struct-get block live-in)
        (compiler-live-scratch-freeze words live-in-count))]
    (CompilerLiveBlock
      (struct-get block label)
      (struct-get block uses)
      (struct-get block defs)
      live-in
      live-out
      (struct-get block successors)
      (struct-get block instr-after))))

(define (compiler-live-block-liveness-eq?
  [left : CompilerLiveBlock]
  [right : CompilerLiveBlock]) : bool
  (and
    (compiler-live-set-eq? (struct-get left live-in) (struct-get right live-in))
    (compiler-live-set-eq?
      (struct-get left live-out)
      (struct-get right live-out))))

(define (compiler-live-worklist-seed! [pending : (Array bool)] [index : i64]) : unit
  (if (>= index (array-length pending))
    unit
    (begin
      (array-set! pending index true)
      (compiler-live-worklist-seed! pending (+ index 1)))))

;; Blocks are laid out in the lowering's deterministic reverse-postorder. For
;; backward liveness, consume that order backwards; changed facts flow only to
;; predecessor blocks, which are re-enqueued at most once while pending.
(define (compiler-live-worklist-pick! [pending : (Array bool)]) : i64
  (let
    [index : i64 (- (array-length pending) 1)]
    [picked : i64 -1]
    (begin
      (while (and (>= index 0) (< picked 0))
        (if (array-ref pending index)
          (begin
            (array-set! pending index false)
            (set! picked index))
          unit)
        (set! index (- index 1)))
      picked)))

(define (compiler-live-worklist-enqueue-predecessors!
  [graph : CompilerLiveBlockGraph]
  [slot : i64]
  [pending : (Array bool)]) : unit
  (let
    [items : (Array i64)
      (struct-get (array-ref (struct-get graph predecessors) slot) items)]
    [i : i64 0]
    (while (< i (array-length items))
      (begin
        (array-set! pending (array-ref items i) true)
        (set! i (+ i 1))))))

(define (compiler-live-instr-seq-fill-after!
  [instrs : CompilerIrInstrSeq]
  [live-out : CompilerLiveI64Set]
  [out : (Array CompilerLiveI64Set)]
  [words : (Array i64)]
  [edge-precise? : bool]) : unit
  (let
    [count : i64 (compiler-ir-instr-seq-count instrs)]
    [index : i64 (- count 1)]
    [at-live-out? : bool true]
    [active-count : i64 (compiler-live-scratch-copy-set! words live-out)]
    (while (>= index 0)
      (let
        [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
        [uses : CompilerLiveI64Set
          (if edge-precise?
            (compiler-live-instr-uses-nophi instr)
            (compiler-live-instr-uses instr))]
        [defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
        (begin
          ;; The final point is already a stored immutable set. Reuse it
          ;; rather than copying scratch once more at every block boundary.
          (array-set!
            out
            index
            (if at-live-out?
              live-out
              (compiler-live-scratch-freeze words active-count)))
          (set! at-live-out? false)
          (set!
            active-count
            (compiler-live-scratch-step! words active-count uses defs))
          (set! index (- index 1)))))))

(define (compiler-live-fill-instr-after-block
  [ir-block : CompilerIrBlock]
  [block : CompilerLiveBlock]
  [words : (Array i64)]
  [edge-precise? : bool]) : CompilerLiveBlock
  (match ir-block
    [(CompilerIrBlock.Block _ instrs)
      (let
        [items : (Array CompilerLiveI64Set)
          (make-array CompilerLiveI64Set (compiler-ir-instr-seq-count instrs))]
        (begin
          (compiler-live-instr-seq-fill-after!
            instrs
            (struct-get block live-out)
            items
            words
            edge-precise?)
          (CompilerLiveBlock
            (struct-get block label)
            (struct-get block uses)
            (struct-get block defs)
            (struct-get block live-in)
            (struct-get block live-out)
            (struct-get block successors)
            (CompilerLiveInstrSetVec items))))]))

(define (compiler-live-analyze-function [func : CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [seq : CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
        [word-count : i64 (compiler-live-var-word-count vars)]
        [build : CompilerLiveFunctionGraphBuild
          (compiler-live-function-graph-build
            seq
            (compiler-live-build-block-array seq vars))]
        [graph : CompilerLiveBlockGraph
          (compiler-live-fixpoint (struct-get build graph) word-count)]
        (begin
          (compiler-live-fill-instr-after-graph-seq!
            (struct-get build seq)
            (struct-get graph blocks)
            word-count
            false)
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
        (match (& (array-ref (struct-get instrs slots) i))
          [(CompilerIrInstr.Phi _ _ _)
            (match (compiler-ir-instr-seq-ref instrs i)
              [(CompilerIrInstr.Phi _ inputs _)
                (compiler-live-phi-out-add-inputs! inputs ids phi-out)]
              [_ unit])]
          [_ unit])
        (set! i (+ i 1))))))

(define (compiler-live-recompute-block-graph-ep
  [block : CompilerLiveBlock]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [phi-out : (Array CompilerLiveI64Set)]
  [words : (Array i64)]) : CompilerLiveBlock
  (let
    [live-out-count : i64
      (compiler-live-successor-live-out-graph-into!
        (array-ref (struct-get graph successors) index)
        graph
        words)]
    [_phi : unit
      (if (and (>= index 0) (< index (array-length phi-out)))
        (set!
          live-out-count
          (compiler-live-scratch-union-set!
            words
            live-out-count
            (array-ref phi-out index)))
        unit)]
    [live-out : CompilerLiveI64Set
      (if (compiler-live-scratch-eq-set?
        words
        live-out-count
        (struct-get block live-out))
        (struct-get block live-out)
        (compiler-live-scratch-freeze words live-out-count))]
    [live-in-count : i64
      (compiler-live-scratch-step!
        words
        live-out-count
        (struct-get block uses)
        (struct-get block defs))]
    [live-in : CompilerLiveI64Set
      (if (compiler-live-scratch-eq-set?
        words
        live-in-count
        (struct-get block live-in))
        (struct-get block live-in)
        (compiler-live-scratch-freeze words live-in-count))]
    (CompilerLiveBlock
      (struct-get block label)
      (struct-get block uses)
      (struct-get block defs)
      live-in
      live-out
      (struct-get block successors)
      (struct-get block instr-after))))

(define (compiler-live-fixpoint-ep
  [graph : CompilerLiveBlockGraph]
  [phi-out : (Array CompilerLiveI64Set)]
  [word-count : i64]) : CompilerLiveBlockGraph
  (let
    [blocks : (Array CompilerLiveBlock) (struct-get graph blocks)]
    [pending : (Array bool)
      (make-array bool (array-length (struct-get graph blocks)))]
    [words : (Array i64) (make-array i64 word-count)]
    [done : bool false]
    (begin
      (compiler-live-worklist-seed! pending 0)
      (while (not done)
        (let
          [index : i64 (compiler-live-worklist-pick! pending)]
          (if (< index 0)
            (set! done true)
            (let
              [block : CompilerLiveBlock (array-ref blocks index)]
              [updated : CompilerLiveBlock
                (compiler-live-recompute-block-graph-ep
                  block
                  graph
                  index
                  phi-out
                  words)]
              (if (compiler-live-block-liveness-eq? block updated)
                unit
                (begin
                  (array-set! blocks index updated)
                  (compiler-live-worklist-enqueue-predecessors!
                    graph
                    index
                    pending)))))))
      graph)))

;; The analysis reads nothing but the block list, so callers holding blocks
;; without a whole CompilerIrFunction (the backend's stack-slot colorer runs on
;; the final rewritten blocks) enter here directly.
(define (compiler-live-analyze-blocks-edge-precise
  [blocks : CompilerIrBlockList]
  [vars : i64]) : CompilerFunctionLiveness
  (let
    [seq : CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
    [word-count : i64 (compiler-live-var-word-count vars)]
    [build : CompilerLiveFunctionGraphBuild
      (compiler-live-function-graph-build
        seq
        (compiler-live-build-block-array-nophi seq vars))]
    [graph0 : CompilerLiveBlockGraph (struct-get build graph)]
    [phi-out : (Array CompilerLiveI64Set)
      (make-array CompilerLiveI64Set (array-length (struct-get graph0 blocks)))]
    (begin
      (let
        [i : i64 0]
        [n : i64 (array-length phi-out)]
        (while (< i n)
          (begin
            (array-set! phi-out i (compiler-live-set-empty))
            (set! i (+ i 1)))))
      (compiler-live-phi-out-build-seq! seq (& (struct-get graph0 ids)) phi-out)
      (let
        [graph : CompilerLiveBlockGraph
          (compiler-live-fixpoint-ep graph0 phi-out word-count)]
        (begin
          (compiler-live-fill-instr-after-graph-seq!
            seq
            (struct-get graph blocks)
            word-count
            true)
          (CompilerFunctionLiveness.Liveness
            (struct-get graph ids)
            (struct-get graph blocks)))))))

(define (compiler-live-analyze-function-edge-precise
  [func : CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(CompilerIrFunction.Function _ _ _ vars blocks)
      (compiler-live-analyze-blocks-edge-precise blocks vars)]))

(define (compiler-live-function-block-index
  [liveness : CompilerFunctionLiveness]
  [label : i64]) : i64
  (match liveness
    [(CompilerFunctionLiveness.Liveness ids _)
      (compiler-live-label-id-map-get (& ids) label)]))

(define (compiler-live-function-find-block
  [liveness : CompilerFunctionLiveness]
  [label : i64]) : CompilerLiveMaybeBlock
  (match liveness
    [(CompilerFunctionLiveness.Liveness ids blocks)
      (let
        [index : i64 (compiler-live-label-id-map-get (& ids) label)]
        (if (>= index 0)
          (CompilerLiveMaybeBlock.Some (array-ref blocks index))
          CompilerLiveMaybeBlock.No))]))

(define (compiler-live-block-uses [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (struct-get block uses))

(define (compiler-live-block-defs [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (struct-get block defs))

(define (compiler-live-block-live-in [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (struct-get block live-in))

(define (compiler-live-block-live-out [block : CompilerLiveBlock]) : CompilerLiveI64Set
  (struct-get block live-out))

(define (compiler-live-block-successor-labels [block : CompilerLiveBlock]) : CompilerLiveLabelSet
  (struct-get block successors))

(define (compiler-live-block-instr-after [block : CompilerLiveBlock]) : CompilerLiveInstrSetVec
  (struct-get block instr-after))

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
  [label : i64]
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
    (compiler-ir-test-symbol "straight")
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
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
    (compiler-ir-test-symbol "branch")
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "then")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "else")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (compiler-live-phi-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (compiler-ir-test-symbol "phi")
    CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "left")
            (compiler-ir-label "right"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              1
              (CompilerIrValue.I64 10)
              (compiler-live-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "right")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                2
                (CompilerIrValue.I64 20)
                (compiler-live-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "join")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  3
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 1)
                    (compiler-ir-label "left")
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 2)
                      (compiler-ir-label "right")
                      CompilerIrPhiInputList.Nil))
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(define (compiler-live-use-def-ok?) : bool
  (let
    [use-def : CompilerLiveUseDef
      (compiler-live-block-use-def
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov
            0
            (CompilerIrValue.Var 10)
            (compiler-live-i64-ty))
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
                  (compiler-ir-test-symbol "f")
                  (CompilerIrCallArgs.Two
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.Var 13))
                  (compiler-live-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "g")
                    (CompilerIrValue.Var 14)
                    (compiler-live-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 15)
                      (compiler-ir-label "a")
                      (compiler-ir-label "b"))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Phi
                        4
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.Var 16)
                          (compiler-ir-label "a")
                          CompilerIrPhiInputList.Nil)
                        (compiler-live-i64-ty))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Return
                          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                        CompilerIrInstrList.Nil)))))))))]
    (and
      (compiler-live-set-eq?
        (struct-get use-def uses)
        (compiler-live-set7 10 11 12 13 14 15 16))
      (compiler-live-set-eq?
        (struct-get use-def defs)
        (compiler-live-set5 0 1 2 3 4)))))

(define (compiler-live-memory-use-def-ok?) : bool
  (let
    [use-def : CompilerLiveUseDef
      (compiler-live-block-use-def
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
                    CompilerIrInstrList.Nil)))))))]
    (and
      (compiler-live-set-eq?
        (struct-get use-def uses)
        (compiler-live-set2 10 11))
      (compiler-live-set-eq?
        (struct-get use-def defs)
        (compiler-live-set5 0 1 2 3 4)))))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (let
    [use-def : CompilerLiveUseDef
      (compiler-live-block-use-def
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
                      CompilerIrInstrList.Nil))))))))]
    (and
      (compiler-live-set-eq?
        (struct-get use-def uses)
        (compiler-live-set5 10 11 12 13 14))
      (compiler-live-set-eq?
        (struct-get use-def defs)
        (compiler-live-set6 0 1 2 3 4 5)))))

(define (compiler-live-straight-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-straight-function))]
    (match (compiler-live-function-find-block
      liveness
      (compiler-ir-label "entry"))
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
            (compiler-live-after liveness (compiler-ir-label "entry") 0)
            (compiler-live-set2 0 2))
          (compiler-live-set-eq?
            (compiler-live-after liveness (compiler-ir-label "entry") 1)
            (compiler-live-set1 1))
          (compiler-live-set-eq?
            (compiler-live-after liveness (compiler-ir-label "entry") 2)
            (compiler-live-set-empty)))]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))]
    (match (compiler-live-function-find-block
      liveness
      (compiler-ir-label "entry"))
      [(CompilerLiveMaybeBlock.Some block)
        (and
          (=
            (compiler-live-label-set-count
              (compiler-live-block-successor-labels block))
            2)
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            (compiler-ir-label "then"))
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            (compiler-ir-label "else"))
          (compiler-live-set-eq?
            (compiler-live-block-live-in block)
            (compiler-live-set3 0 1 2)))]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))]
    (match (compiler-live-function-find-block
      liveness
      (compiler-ir-label "join"))
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
            (compiler-live-after liveness (compiler-ir-label "join") 0)
            (compiler-live-set1 3))
          (match (compiler-live-function-find-block
            liveness
            (compiler-ir-label "left"))
            [(CompilerLiveMaybeBlock.Some left-block)
              (compiler-live-label-set-contains?
                (compiler-live-block-successor-labels left-block)
                (compiler-ir-label "join"))]
            [(CompilerLiveMaybeBlock.No) false]))]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-phi-edge-precise-ok?) : bool
  (let
    [baseline : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-phi-function))]
    [edge-precise : CompilerFunctionLiveness
      (compiler-live-analyze-function-edge-precise (compiler-live-phi-function))]
    (match (compiler-live-function-find-block
      baseline
      (compiler-ir-label "join"))
      [(CompilerLiveMaybeBlock.Some baseline-join)
        (match (compiler-live-function-find-block
          edge-precise
          (compiler-ir-label "join"))
          [(CompilerLiveMaybeBlock.Some edge-precise-join)
            (match (compiler-live-function-find-block
              baseline
              (compiler-ir-label "left"))
              [(CompilerLiveMaybeBlock.Some baseline-left)
                (match (compiler-live-function-find-block
                  edge-precise
                  (compiler-ir-label "left"))
                  [(CompilerLiveMaybeBlock.Some edge-precise-left)
                    (match (compiler-live-function-find-block
                      edge-precise
                      (compiler-ir-label "right"))
                      [(CompilerLiveMaybeBlock.Some edge-precise-right)
                        (and
                          (compiler-live-set-eq?
                            (compiler-live-block-uses baseline-join)
                            (compiler-live-set2 1 2))
                          (compiler-live-set-eq?
                            (compiler-live-block-uses edge-precise-join)
                            (compiler-live-set-empty))
                          (compiler-live-set-eq?
                            (compiler-live-block-live-in edge-precise-join)
                            (compiler-live-set-empty))
                          (compiler-live-set-eq?
                            (compiler-live-block-live-out baseline-left)
                            (compiler-live-set2 1 2))
                          (compiler-live-set-eq?
                            (compiler-live-block-live-out edge-precise-left)
                            (compiler-live-set1 1))
                          (compiler-live-set-eq?
                            (compiler-live-block-live-out edge-precise-right)
                            (compiler-live-set1 2)))]
                      [(CompilerLiveMaybeBlock.No) false])]
                  [(CompilerLiveMaybeBlock.No) false])]
              [(CompilerLiveMaybeBlock.No) false])]
          [(CompilerLiveMaybeBlock.No) false])]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-switch-ok?) : bool
  (let
    [cases : CompilerIrSwitchCaseList
      (compiler-ir-switch-case-cons
        4
        (compiler-ir-label "four")
        (compiler-ir-switch-case-cons
          5
          (compiler-ir-label "five")
          CompilerIrSwitchCaseList.Nil))]
    [instr : CompilerIrInstr
      (CompilerIrInstr.Switch
        (CompilerIrValue.Var 9)
        4
        cases
        (compiler-ir-label "other"))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons instr CompilerIrInstrList.Nil)]
    [block : CompilerIrBlock
      (compiler-ir-block (compiler-ir-label "entry") instrs)]
    [successors : CompilerLiveLabelSet (compiler-live-block-successors block)]
    [use-def : CompilerLiveUseDef (compiler-live-block-use-def instrs)]
    (and
      (compiler-live-set-eq? (struct-get use-def uses) (compiler-live-set1 9))
      (compiler-live-set-eq?
        (struct-get use-def defs)
        (compiler-live-set-empty))
      (= (compiler-live-label-set-count successors) 3)
      (compiler-live-label-set-contains? successors (compiler-ir-label "four"))
      (compiler-live-label-set-contains? successors (compiler-ir-label "five"))
      (compiler-live-label-set-contains? successors (compiler-ir-label "other")))))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-set-ops-ok?)
    (compiler-live-scratch-ops-ok?)
    (compiler-live-use-def-ok?)
    (compiler-live-memory-use-def-ok?)
    (compiler-live-vector-mask-use-def-ok?)
    (compiler-live-straight-ok?)
    (compiler-live-branch-ok?)
    (compiler-live-phi-ok?)
    (compiler-live-phi-edge-precise-ok?)
    (compiler-live-switch-ok?))
    42
    (io.panic "liveness: smoke mismatch")))

;; Dense-array path for liveness analysis.
;; Avoids linked-list allocation overhead in the hot self-compile path.
(define (compiler-live-ir-block-list-to-seq [blocks : CompilerIrBlockList]) : CompilerIrBlockSeq
  (match blocks
    [(CompilerIrBlockList.Array seq) seq]
    [_ (compiler-ir-block-seq-from-list blocks)]))

(define (compiler-live-build-block-array-with
  [blocks : CompilerIrBlockSeq]
  [vars : i64]
  [edge-precise? : bool]) : (Array CompilerLiveBlock)
  (let
    [count : i64 (compiler-ir-block-seq-count blocks)]
    [out : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
    [word-count : i64 (compiler-live-var-word-count vars)]
    [uses : (Array i64) (make-array i64 word-count)]
    [defs : (Array i64) (make-array i64 word-count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (let
          [block : CompilerIrBlock (compiler-ir-block-seq-ref blocks i)]
          (begin
            (match block
              [(CompilerIrBlock.Block _ instrs)
                (array-set!
                  out
                  i
                  (compiler-live-build-block-from-use-def
                    block
                    (compiler-live-block-use-def-seq-with-scratch
                      instrs
                      uses
                      defs
                      edge-precise?)))])
            (set! i (+ i 1)))))
      out)))

(define (compiler-live-build-block-array
  [blocks : CompilerIrBlockSeq]
  [vars : i64]) : (Array CompilerLiveBlock)
  (compiler-live-build-block-array-with blocks vars false))

(define (compiler-live-build-block-array-nophi
  [blocks : CompilerIrBlockSeq]
  [vars : i64]) : (Array CompilerLiveBlock)
  (compiler-live-build-block-array-with blocks vars true))

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
    (let
      [block : CompilerLiveBlock (array-ref blocks index)]
      (begin
        (array-set!
          successors
          index
          (compiler-live-label-set-to-index-vec
            (struct-get block successors)
            ids))
        (compiler-live-block-graph-fill-successors-from-array!
          blocks
          ids
          successors
          (+ index 1))))))

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
        (let
          [block : CompilerLiveBlock (array-ref blocks i)]
          [_inserted : bool
            (live_label_map.insert-if-absent-ref!
              (&mut ids)
              (struct-get block label)
              i)]
          unit)
        (set! i (+ i 1)))
      (compiler-live-block-graph-fill-successors-from-array!
        blocks
        (& ids)
        successors
        0)
      (CompilerLiveBlockGraph
        ids
        blocks
        successors
        (compiler-live-predecessors-build successors)))))

(define (compiler-live-function-graph-build
  [seq : CompilerIrBlockSeq]
  [live-blocks : (Array CompilerLiveBlock)]) : CompilerLiveFunctionGraphBuild
  (let
    [graph : CompilerLiveBlockGraph
      (compiler-live-block-graph-build-from-array live-blocks)]
    (CompilerLiveFunctionGraphBuild seq graph)))

(define (compiler-live-fill-instr-after-graph-seq!
  [ir-blocks : CompilerIrBlockSeq]
  [blocks : (Array CompilerLiveBlock)]
  [word-count : i64]
  [edge-precise? : bool]) : unit
  (let
    [count : i64
      (compiler-live-set-min
        (compiler-ir-block-seq-count ir-blocks)
        (array-length blocks))]
    [words : (Array i64) (make-array i64 word-count)]
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set!
          blocks
          i
          (compiler-live-fill-instr-after-block
            (compiler-ir-block-seq-ref ir-blocks i)
            (array-ref blocks i)
            words
            edge-precise?))
        (set! i (+ i 1))))))

(define (compiler-live-fixpoint
  [graph : CompilerLiveBlockGraph]
  [word-count : i64]) : CompilerLiveBlockGraph
  (let
    [blocks : (Array CompilerLiveBlock) (struct-get graph blocks)]
    [pending : (Array bool)
      (make-array bool (array-length (struct-get graph blocks)))]
    [words : (Array i64) (make-array i64 word-count)]
    [done : bool false]
    (begin
      (compiler-live-worklist-seed! pending 0)
      (while (not done)
        (let
          [index : i64 (compiler-live-worklist-pick! pending)]
          (if (< index 0)
            (set! done true)
            (let
              [block : CompilerLiveBlock (array-ref blocks index)]
              [updated : CompilerLiveBlock
                (compiler-live-recompute-block-graph block graph index words)]
              (if (compiler-live-block-liveness-eq? block updated)
                unit
                (begin
                  (array-set! blocks index updated)
                  (compiler-live-worklist-enqueue-predecessors!
                    graph
                    index
                    pending)))))))
      graph)))