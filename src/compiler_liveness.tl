;; compiler_liveness.tl - Self-hosted CompilerIrFunction liveness analysis.
;;
;; This module keeps the selfhost liveness pass deterministic while storing
;; integer live sets as compact bitsets keyed by dense IR variable ids. Do not
;; replace CompilerLiveI64Set with the general `(set i64)` family without a
;; compiler-path benchmark: opt2 self-compile is sensitive to liveness set
;; iteration and copy costs.
(import stdlib.io)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as live_label_map)

(defstruct CompilerLiveI64Set
  (words (__tl_dyn-array i64)))

(defenum CompilerLiveLabelSet
  (Nil)
  ;; Successor labels in deterministic head-first order. The logical head is
  ;; the end of the dense prefix, which makes tail views allocation-free.
  (Dense (__tl_dyn-array i64) i64))

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
        [items : (__tl_dyn-array i64) (make-array i64 4)]
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
          [bigger : (__tl_dyn-array i64) (make-array i64 capacity)]
          [index : i64 0]
          (begin
            (while (< index len)
              (begin
                (array-set! bigger index (array-ref items index))
                (set! index (+ index 1))))
            (array-set! bigger len value)
            (CompilerLiveLabelSet.Dense bigger (+ len 1)))))]))

(defstruct CompilerLiveIndexVec
  (items (__tl_dyn-array i64)))

(defstruct CompilerLiveInstrSetVec
  (items (__tl_dyn-array CompilerLiveI64Set)))

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
  (blocks (__tl_dyn-array CompilerLiveBlock))
  (successors (__tl_dyn-array CompilerLiveIndexVec))
  (predecessors (__tl_dyn-array CompilerLiveIndexVec)))

(defstruct CompilerLiveFunctionGraphBuild
  (seq ir.CompilerIrBlockSeq)
  (graph CompilerLiveBlockGraph))

(defenum CompilerFunctionLiveness
  (Liveness live_label_map.Map (__tl_dyn-array CompilerLiveBlock)))

(defenum CompilerLiveMaybeBlock
  (No)
  (Some CompilerLiveBlock))

(defenum CompilerLiveMaybeInstr
  (No)
  (Some ir.CompilerIrInstr))

(defstruct CompilerLiveUseDef
  (uses CompilerLiveI64Set)
  (defs CompilerLiveI64Set))

(define (compiler-live-instr-set-vec-empty) : CompilerLiveInstrSetVec
  (CompilerLiveInstrSetVec (make-array CompilerLiveI64Set 0)))

(unsafe
  (extern (live-runtime-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [count : i64]) : unit (:symbol "tl_memcpy")))

;; Word count at which a bulk `tl_memcpy` beats copying a live-set word range
;; one i64 at a time.
;;
;; The scalar arm is the load/store/index/compare/branch body the backend emits
;; for a dense word walk, five or six instructions per word. `tl_memcpy` costs
;; thirteen instructions of direction/overlap dispatch plus one `rep movsq` step
;; per eight bytes, and reaching it costs the argument moves and the `call`.
;; That is roughly `5n` against `18 + n`, which crosses just above four words.
;;
;; The threshold is not a guess and the scalar arm is not vestigial: a
;; word-count census over an opt2 self-compile puts half of every live-set copy
;; at three words or fewer (freezes: 4.9% empty, 25.9% one word, 14.2% two,
;; 10.1% three; the range copies are wider still at the tail but 52% of them are
;; also three or fewer). Those calls are half the traffic and 7% of the words,
;; so they must keep the cheap arm while the long tail -- which is where nearly
;; all the words are -- takes the bulk copy.
(define (compiler-live-set-bulk-copy-words) : i64
  5)

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

(define (compiler-live-set-words [set : CompilerLiveI64Set]) : (__tl_dyn-array
    i64)
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

;; There is no bounds-checked `compiler-live-set-word-at` any more. It existed
;; to answer "the word at this index, or 0 when the set is too short" behind a
;; call; P41 spelled that out inside `compiler-live-set-contains?` and P42 did
;; the same for `compiler-live-set-insert` and `compiler-live-set-eq?`, which
;; were the last two callers. Every remaining word read either proves its index
;; in range and uses `-bounded` / `-at-data`, or spells the short-set arm out
;; where the array's own length is already loaded.
;;
;; Callers must prove `0 <= word-index < compiler-live-set-word-count set`.
(define (compiler-live-set-word-at-bounded
  [set : CompilerLiveI64Set]
  [word-index : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-offset (array-data (compiler-live-set-words set)) word-index))))

;; The backing pointer `compiler-live-set-word-at-bounded` reloads on every
;; call: the set handle, the array handle behind it, and the data pointer behind
;; that are three dependent loads a walk repeats per word. A walk that reads
;; many words takes the pointer once with this and indexes it with
;; `compiler-live-set-word-at-data`. Heap allocation is a bump into the active
;; arena and nothing is ever moved or freed under a live value, so the pointer
;; stays valid for as long as the set does -- including across calls that
;; allocate, as long as they do not write to this set.
(define (compiler-live-set-word-data [set : CompilerLiveI64Set]) : (MutPtr i64)
  (unsafe
    (array-data (compiler-live-set-words set))))

;; Same word `compiler-live-set-word-at-bounded` returns for this index, read
;; through a pointer the caller hoisted with `compiler-live-set-word-data`.
;; Callers must prove `0 <= word-index < compiler-live-set-word-count set`.
(define (compiler-live-set-word-at-data
  [data : (MutPtr i64)]
  [word-index : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset data word-index))))

;; Copy `src[index, count)` into the same range of `dst`. Both callers below
;; allocate `dst` fresh at a length that covers `count` and never pass a `count`
;; past the end of `src`, so `dst` and `src` are always distinct arrays and the
;; range is in bounds for both -- the recursive `array-ref`/`array-set!` form
;; this replaces re-read both lengths and re-tested them on every word, which is
;; four of the fourteen instructions it spent per word. Reading the backing
;; pointers once and indexing them directly leaves the five-instruction word
;; body, and once the range is wide enough to pay for the call (see
;; `compiler-live-set-bulk-copy-words`) `tl_memcpy` moves it eight bytes per
;; instruction instead. Distinct arrays means the ranges cannot overlap, so the
;; forward bulk copy sees exactly what the ascending word walk saw.
(define (compiler-live-set-copy-words-into
  [dst : (__tl_dyn-array i64)]
  [src : (__tl_dyn-array i64)]
  [index : i64]
  [count : i64]) : unit
  (let
    [words : i64 (- count index)]
    (if (<= words 0)
      unit
      (let
        [src-data : (MutPtr i64)
          (unsafe
            (array-data src))]
        [dst-data : (MutPtr i64)
          (unsafe
            (array-data dst))]
        (if (< words (compiler-live-set-bulk-copy-words))
          (let
            [at : i64 index]
            (while (< at count)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset dst-data at)
                    (ptr-read (ptr-offset src-data at))))
                (set! at (+ at 1)))))
          (unsafe
            (live-runtime-copy-bytes!
              (ptr-cast (ptr-offset dst-data index) : (MutPtr u8))
              (ptr-cast (ptr-offset src-data index) : (Ptr u8))
              (* words 8))))))))

(define (compiler-live-set-copy-with-capacity
  [set : CompilerLiveI64Set]
  [capacity : i64]) : (__tl_dyn-array i64)
  (let
    [words : (__tl_dyn-array i64) (compiler-live-set-words set)]
    [old-capacity : i64 (array-length words)]
    [out : (__tl_dyn-array i64) (make-array i64 capacity)]
    [copy-count : i64 (compiler-live-set-min old-capacity capacity)]
    (begin
      (compiler-live-set-copy-words-into out words 0 copy-count)
      out)))

(define (compiler-live-set-trim-length
  [words : (__tl_dyn-array i64)]
  [count : i64]) : i64
  (let
    [i : i64 count]
    (begin
      (while (and (> i 0) (= (array-ref words (- i 1)) 0))
        (set! i (- i 1)))
      i)))

(define (compiler-live-set-from-words-trimmed
  [words : (__tl_dyn-array i64)]
  [count : i64]) : CompilerLiveI64Set
  (let
    [n : i64 (compiler-live-set-trim-length words count)]
    (if (<= n 0)
      (compiler-live-set-empty)
      (if (= n (array-length words))
        (CompilerLiveI64Set words)
        (let
          [out : (__tl_dyn-array i64) (make-array i64 n)]
          (begin
            (compiler-live-set-copy-words-into out words 0 n)
            (CompilerLiveI64Set out)))))))

;; Membership is the hottest liveness primitive in an opt2 self-compile --
;; 13,669,761 calls spread over 25 register-allocator and backend sites, none of
;; them dominant -- so the word read is spelled out here instead of going through
;; the bounds-checked `compiler-live-set-word-at` helper this used to call (P42
;; retired it once `insert` and `eq?` stopped calling it too). What that helper
;; charged THIS caller was a call/ret and an argument move, a
;; `word-index < 0` test that the `value < 0` guard above already decides (a
;; non-negative value cannot shift right into a negative index), and -- because
;; the mask has to survive the call -- a callee-saved register plus the frame to
;; save and restore it in. Everything the helper does for an in-range index is
;; done here directly, and an out-of-range index still answers false: the helper
;; returned word 0 for it, and 0 masks to 0.
;;
;; The RANGE test now runs before the mask is built, and that is the larger half
;; of the win rather than a tidying: 46% of the calls in an opt2 self-compile
;; answer false without reading a word (measured -- the average call costs 19.7
;; instructions against 28 for the full path), and every one of them used to pay
;; for `compiler-live-set-bit-mask` first, which is a `shl` by a computed amount
;; and so carries the two range checks the shift itself needs. Deciding the
;; cheap, always-needed comparison first lets those calls skip the whole
;; sequence.
(define (compiler-live-set-contains? [set : CompilerLiveI64Set] [value : i64]) : bool
  (if (< value 0)
    false
    (let
      [words : (__tl_dyn-array i64) (compiler-live-set-words set)]
      [word-index : i64 (compiler-live-set-word-index value)]
      (if (>= word-index (array-length words))
        false
        (not
          (=
            (bit-and
              (unsafe
                (ptr-read (ptr-offset (array-data words) word-index)))
              (compiler-live-set-bit-mask value))
            0))))))

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

;; The word read is spelled out rather than routed through the bounds-checked
;; `compiler-live-set-word-at` helper, for the reason P41 gave for
;; `compiler-live-set-contains?`: the call reloads the word array
;; handle that `compiler-live-set-word-count` has already loaded one line above,
;; and both are on the hot path of a function the liveness walk runs 2.4M times
;; in an opt2 self-compile. Taking `words` once serves the count, the range test
;; and the read. The helper's `word-index >= 0` half is dropped with it: `value`
;; is non-negative on this arm and `compiler-live-set-word-index` is a right
;; shift, so a negative index cannot arise here. The capacity `max` is spelled
;; inline for P28's reason -- it is a real out-of-line call with 28 other sites
;; keeping it that way, and this one sits on the hot path.
(define (compiler-live-set-insert [set : CompilerLiveI64Set] [value : i64]) : CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [words : (__tl_dyn-array i64) (compiler-live-set-words set)]
      [word-count : i64 (array-length words)]
      [word-index : i64 (compiler-live-set-word-index value)]
      [mask : i64 (compiler-live-set-bit-mask value)]
      [capacity : i64
        (if (< word-count (+ word-index 1))
          (+ word-index 1)
          word-count)]
      [old-bits : i64
        (if (< word-index word-count)
          (unsafe
            (ptr-read (ptr-offset (array-data words) word-index)))
          0)]
      (if (not (= (bit-and old-bits mask) 0))
        set
        (let
          [out : (__tl_dyn-array i64)
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
              [out : (__tl_dyn-array i64)
                (compiler-live-set-copy-with-capacity set capacity)]
              (begin
                (array-set! out word-index (bit-and old-bits (bit-xor mask -1)))
                (compiler-live-set-from-words-trimmed out capacity)))))))))

(define (compiler-live-set-union
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [left-words : (__tl_dyn-array i64) (compiler-live-set-words left)]
    [right-words : (__tl_dyn-array i64) (compiler-live-set-words right)]
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
                [out : (__tl_dyn-array i64) (make-array i64 count)]
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
    [left-words : (__tl_dyn-array i64) (compiler-live-set-words left)]
    [right-words : (__tl_dyn-array i64) (compiler-live-set-words right)]
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
          [out : (__tl_dyn-array i64) (make-array i64 count)]
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

;; Two `compiler-live-set-word-at` calls per word was the whole cost of this
;; comparison: each reloaded the set handle, the array handle behind it and the
;; data pointer behind that, for one i64. Both arrays' handles, lengths and
;; backing pointers are taken once here and the reads are spelled out, exactly
;; as P41 did inside `compiler-live-set-contains?`. This was the helper's last
;; caller together with `compiler-live-set-insert`, so it is gone. The short-set
;; arm it provided is kept verbatim -- a set narrower than `count` reads 0 for
;; its trailing words, which is what a missing word means -- so the same word
;; pairs are compared in the same order and the same answer comes out.
;;
;; The range proof is local: `index` starts at 0 and only ever increments, and
;; each read is guarded against that array's OWN length, so no caller contract
;; is involved. The pointers cannot go stale either -- with the calls gone the
;; loop body contains none at all, so nothing in it can allocate.
(define (compiler-live-set-eq?
  [left : CompilerLiveI64Set]
  [right : CompilerLiveI64Set]) : bool
  (let
    [left-words : (__tl_dyn-array i64) (compiler-live-set-words left)]
    [right-words : (__tl_dyn-array i64) (compiler-live-set-words right)]
    [left-count : i64 (array-length left-words)]
    [right-count : i64 (array-length right-words)]
    [count : i64
      (if (< left-count right-count)
        right-count
        left-count)]
    [left-data : (MutPtr i64)
      (unsafe
        (array-data left-words))]
    [right-data : (MutPtr i64)
      (unsafe
        (array-data right-words))]
    [index : i64 0]
    [same : bool true]
    (begin
      (while (and same (< index count))
        (let
          [left-bits : i64
            (if (< index left-count)
              (unsafe
                (ptr-read (ptr-offset left-data index)))
              0)]
          [right-bits : i64
            (if (< index right-count)
              (unsafe
                (ptr-read (ptr-offset right-data index)))
              0)]
          (if (= left-bits right-bits)
            (set! index (+ index 1))
            (set! same false))))
      same)))

;; Mutable liveness scratch keeps the changing dataflow facts in one
;; function-sized word row. CompilerLiveI64Set remains the canonical stored
;; representation: scratch is copied and trimmed only when a block fact or
;; instruction point must outlive the current walk.
(define (compiler-live-scratch-clear! [words : (__tl_dyn-array i64)]) : unit
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
  [words : (__tl_dyn-array i64)]
  [set : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [src-words : (__tl_dyn-array i64) (compiler-live-set-words set)]
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
  [words : (__tl_dyn-array i64)]
  [active-count : i64]
  [set : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [src-words : (__tl_dyn-array i64) (compiler-live-set-words set)]
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

;; Id form of compiler-live-scratch-step!: `live = (live & ~defs) | uses` for a
;; one-def, few-use instruction, without walking the live row.
;;
;; The word form rewrites EVERY word below `max(active, use-words, def-words)`,
;; which is the whole live row -- a 30-word row pays 30 read-modify-writes to
;; move two bits. Clearing the single def bit and then setting the use bits
;; produces the same row: words the sets do not name are rewritten to
;; themselves, `use` wins over `def` for a var that is both (the word form ORs
;; the uses in after masking the defs out), and scratch words at or above
;; `active-count` are zero, so the word form's writes there are exactly the use
;; bits. `count` is computed from the same three widths, so the returned trim
;; length is the same too.
(define (compiler-live-scratch-step-ids!
  [words : (__tl_dyn-array i64)]
  [active-count : i64]
  [ids : (__tl_dyn-array i64)]
  [id-count : i64]
  [def-var : i64]) : i64
  (let
    [count : i64 active-count]
    [index : i64 0]
    (begin
      (if (< def-var 0)
        unit
        (let
          [word : i64 (compiler-live-set-word-index def-var)]
          (begin
            (set! count (compiler-live-set-max count (+ word 1)))
            (array-set!
              words
              word
              (bit-and
                (array-ref words word)
                (bit-xor (compiler-live-set-bit-mask def-var) -1))))))
      (while (< index id-count)
        (let
          [var : i64 (array-ref ids index)]
          [word : i64 (compiler-live-set-word-index var)]
          (begin
            (set! count (compiler-live-set-max count (+ word 1)))
            (array-set!
              words
              word
              (bit-or (array-ref words word) (compiler-live-set-bit-mask var)))
            (set! index (+ index 1)))))
      (compiler-live-set-trim-length words count))))

(define (compiler-live-scratch-step!
  [words : (__tl_dyn-array i64)]
  [active-count : i64]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : i64
  (let
    [dst : (MutPtr i64)
      (unsafe
        (array-data words))]
    [use-words : (__tl_dyn-array i64) (compiler-live-set-words uses)]
    [def-words : (__tl_dyn-array i64) (compiler-live-set-words defs)]
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
  [words : (__tl_dyn-array i64)]
  [active-count : i64]
  [set : CompilerLiveI64Set]) : bool
  (let
    [set-count : i64 (compiler-live-set-word-count set)]
    [data : (MutPtr i64)
      (unsafe
        (array-data words))]
    [set-words : (__tl_dyn-array i64) (compiler-live-set-words set)]
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
  [words : (__tl_dyn-array i64)]
  [active-count : i64]) : CompilerLiveI64Set
  (let
    [count : i64 (compiler-live-set-trim-length words active-count)]
    (if (<= count 0)
      (compiler-live-set-empty)
      (let
        [out : (__tl_dyn-array i64) (make-array i64 count)]
        [src : (MutPtr i64)
          (unsafe
            (array-data words))]
        [dst : (MutPtr i64)
          (unsafe
            (array-data out))]
        [index : i64 0]
        (begin
          ;; `out` is the allocation two lines up, so it can never be the array
          ;; `words` points at and the two ranges cannot overlap -- the bulk
          ;; copy therefore reads exactly what the ascending word walk read.
          ;; Freezes are short: half of them are three words or fewer, which is
          ;; under the width where the call pays for itself, so the word walk
          ;; stays for those (see `compiler-live-set-bulk-copy-words`).
          (if (< count (compiler-live-set-bulk-copy-words))
            (while (< index count)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset dst index)
                    (ptr-read (ptr-offset src index))))
                (set! index (+ index 1))))
            (unsafe
              (live-runtime-copy-bytes!
                (ptr-cast dst : (MutPtr u8))
                (ptr-cast src : (Ptr u8))
                (* count 8))))
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

(define (compiler-live-set-builder-insert!
  [words : (__tl_dyn-array i64)]
  [value : i64]) : unit
  (if (< value 0)
    unit
    (let
      [word-index : i64 (compiler-live-set-word-index value)]
      [old-bits : i64 (array-ref words word-index)]
      (array-set!
        words
        word-index
        (bit-or old-bits (compiler-live-set-bit-mask value))))))

(define (compiler-live-set-builder [max-value : i64]) : (__tl_dyn-array i64)
  (make-array
    i64
    (if (< max-value 0)
      0
      (+ (compiler-live-set-word-index max-value) 1))))

(define (compiler-live-set1 [a : i64]) : CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64) (compiler-live-set-builder a)]
    (begin
      (compiler-live-set-builder-insert! words a)
      (CompilerLiveI64Set words))))

(define (compiler-live-set2 [a : i64] [b : i64]) : CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (compiler-live-set-builder (compiler-live-set-max a b))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (CompilerLiveI64Set words))))

(define (compiler-live-set3 [a : i64] [b : i64] [c : i64]) : CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (compiler-live-set-builder
        (compiler-live-set-max (compiler-live-set-max a b) c))]
    (begin
      (compiler-live-set-builder-insert! words a)
      (compiler-live-set-builder-insert! words b)
      (compiler-live-set-builder-insert! words c)
      (CompilerLiveI64Set words))))

(define (compiler-live-set4 [a : i64] [b : i64] [c : i64] [d : i64]) : CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
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
    [words : (__tl_dyn-array i64)
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
    [words : (__tl_dyn-array i64)
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
    [words : (__tl_dyn-array i64)
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
    [words : (__tl_dyn-array i64) (make-array i64 6)]
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

;; Differential proof for the direct-id API: the ids an instruction hands over
;; must describe exactly the sets the bitset decode builds. Every id-driven
;; consumer rests on this, so it is checked per instruction rather than per
;; consumer.
(define (compiler-live-instr-ids-match-set? [instr : ir.CompilerIrInstr]) : bool
  (let
    [uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
    [defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
    [def-var : i64 (compiler-live-instr-def-var instr)]
    [ids : (__tl_dyn-array i64) (compiler-live-instr-ids)]
    [id-count : i64 (compiler-live-instr-use-ids! instr)]
    [index : i64 0]
    [ok : bool (= id-count (compiler-live-set-count uses))]
    (begin
      (while (< index id-count)
        (begin
          (if (compiler-live-set-contains? uses (array-ref ids index))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      (and
        ok
        (=
          (compiler-live-set-count defs)
          (if (< def-var 0)
            0
            1))
        (or (< def-var 0) (compiler-live-set-contains? defs def-var))))))

(define (compiler-live-instr-ids-list-match-set?
  [instrs : ir.CompilerIrInstrList]) : bool
  (match instrs
    [(ir.CompilerIrInstrList.Nil) true]
    [(ir.CompilerIrInstrList.Cons instr rest)
      (and
        (compiler-live-instr-ids-match-set? instr)
        (compiler-live-instr-ids-list-match-set? (box-get rest)))]))

;; Instruction shapes that exercise the parts of the decode a straight
;; one-operand arm does not: a repeated operand (the set de-duplicates, so the
;; id list must too), a two-arg call, a phi input list, a packed value list, a
;; raw-var AddrOf operand, and a def-less terminator.
(define (compiler-live-ids-sample-instrs) : ir.CompilerIrInstrList
  (ir.compiler-ir-instr-cons
    (ir.CompilerIrInstr.Mov
      0
      (ir.CompilerIrValue.Var 10)
      (compiler-live-i64-ty))
    (ir.compiler-ir-instr-cons
      (ir.CompilerIrInstr.BinOp
        1
        ir.CompilerIrBinOp.Add
        (ir.CompilerIrValue.Var 7)
        (ir.CompilerIrValue.Var 7)
        (compiler-live-i64-ty))
      (ir.compiler-ir-instr-cons
        (ir.CompilerIrInstr.AddrOf 2 33)
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Gep
            3
            (ir.CompilerIrValue.Var 40)
            (ir.CompilerIrValue.I64 8)
            (compiler-live-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Call
              4
              (ir.compiler-ir-test-symbol "f")
              (ir.CompilerIrCallArgs.Two
                (ir.CompilerIrValue.Var 41)
                (ir.CompilerIrValue.Var 41))
              (compiler-live-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Pack
                5
                (ir.compiler-ir-value-cons
                  (ir.CompilerIrValue.Var 42)
                  (ir.compiler-ir-value-cons
                    (ir.CompilerIrValue.Var 43)
                    ir.CompilerIrValueList.Nil))
                (compiler-live-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Phi
                  6
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 44)
                    (ir.compiler-ir-label "a")
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 44)
                      (ir.compiler-ir-label "b")
                      ir.CompilerIrPhiInputList.Nil))
                  (compiler-live-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.StorePtr
                    (ir.CompilerIrValue.Var 45)
                    (ir.CompilerIrValue.Var 46)
                    (compiler-live-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Var 47)
                      (ir.compiler-ir-label "a")
                      (ir.compiler-ir-label "b"))
                    ir.CompilerIrInstrList.Nil))))))))))

;; The two id-driven scratch steps must leave the row -- and the trimmed active
;; count -- exactly where the bitset forms leave them.
(define (compiler-live-step-ids-ok?) : bool
  (let
    [set-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-words : (__tl_dyn-array i64) (make-array i64 6)]
    [ids : (__tl_dyn-array i64) (make-array i64 4)]
    [set-use-words : (__tl_dyn-array i64) (make-array i64 6)]
    [set-def-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-use-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-def-words : (__tl_dyn-array i64) (make-array i64 6)]
    [seed : CompilerLiveI64Set (compiler-live-set3 1 64 130)]
    [set-active : i64 (compiler-live-scratch-copy-set! set-words seed)]
    [id-active : i64 (compiler-live-scratch-copy-set! id-words seed)]
    ;; `130` is used and defined here, and `1` is only defined: the def clear
    ;; must lose `1`, the use must keep `130`, and the row must grow to hold the
    ;; new use `191`.
    [_ids-fill : unit
      (begin
        (array-set! ids 0 130)
        (array-set! ids 1 191))]
    [set-count : i64
      (compiler-live-scratch-step!
        set-words
        set-active
        (compiler-live-set2 130 191)
        (compiler-live-set1 1))]
    [id-count : i64
      (compiler-live-scratch-step-ids! id-words id-active ids 2 1)]
    [step-ok : bool
      (and
        (= set-count id-count)
        (compiler-live-set-eq?
          (compiler-live-scratch-freeze set-words set-count)
          (compiler-live-scratch-freeze id-words id-count)))]
    ;; The block use/def accumulation: `9` is already defined by an earlier
    ;; instruction, so using it here must NOT make it a block use; `70` must.
    [_seed-defs : unit
      (begin
        (compiler-live-set-builder-insert! set-def-words 9)
        (compiler-live-set-builder-insert! id-def-words 9))]
    [_step2-ids : unit
      (begin
        (array-set! ids 0 9)
        (array-set! ids 1 70))]
    [_set-step : unit
      (compiler-live-block-use-def-step!
        set-use-words
        set-def-words
        (compiler-live-set2 9 70)
        (compiler-live-set1 130))]
    [_id-step : unit
      (compiler-live-block-use-def-step-ids!
        id-use-words
        id-def-words
        ids
        2
        130)]
    [use-def-ok : bool
      (and
        (compiler-live-set-eq?
          (compiler-live-scratch-freeze set-use-words 6)
          (compiler-live-set1 70))
        (compiler-live-set-eq?
          (compiler-live-scratch-freeze set-use-words 6)
          (compiler-live-scratch-freeze id-use-words 6))
        (compiler-live-set-eq?
          (compiler-live-scratch-freeze set-def-words 6)
          (compiler-live-scratch-freeze id-def-words 6)))]
    ;; A use list wider than the buffer reports -1 so the caller can fall back.
    [narrow : (__tl_dyn-array i64) (make-array i64 1)]
    [overflow-ok : bool
      (=
        (compiler-live-instr-use-ids-into!
          (ir.CompilerIrInstr.StorePtr
            (ir.CompilerIrValue.Var 3)
            (ir.CompilerIrValue.Var 4)
            (compiler-live-i64-ty))
          narrow)
        -1)]
    (and
      step-ok
      use-def-ok
      overflow-ok
      (compiler-live-instr-ids-list-match-set?
        (compiler-live-ids-sample-instrs)))))

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

(define (compiler-live-value-vars [value : ir.CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(ir.CompilerIrValue.Var id) (compiler-live-set1 id)]
    [_ (compiler-live-set-empty)]))

(define (compiler-live-value-vars-into
  [set : CompilerLiveI64Set]
  [value : ir.CompilerIrValue]) : CompilerLiveI64Set
  (match value
    [(ir.CompilerIrValue.Var id) (compiler-live-set-insert set id)]
    [_ set]))

(define (compiler-live-values2-vars
  [a : ir.CompilerIrValue]
  [b : ir.CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-value-vars b) a))

(define (compiler-live-values3-vars
  [a : ir.CompilerIrValue]
  [b : ir.CompilerIrValue]
  [c : ir.CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-values2-vars b c) a))

(define (compiler-live-values4-vars
  [a : ir.CompilerIrValue]
  [b : ir.CompilerIrValue]
  [c : ir.CompilerIrValue]
  [d : ir.CompilerIrValue]) : CompilerLiveI64Set
  (compiler-live-value-vars-into (compiler-live-values3-vars b c d) a))

(define (compiler-live-value-list-vars [values : ir.CompilerIrValueList]) : CompilerLiveI64Set
  (match (ir.compiler-ir-value-list-force-cons values)
    [(ir.CompilerIrValueList.Nil) (compiler-live-set-empty)]
    [(ir.CompilerIrValueList.Array seq)
      (compiler-live-value-list-vars (ir.compiler-ir-value-seq-to-list seq))]
    [(ir.CompilerIrValueList.Cons value rest)
      (compiler-live-value-vars-into
        (compiler-live-value-list-vars (box-get rest))
        value)]))

(define (compiler-live-call-args-array-vars
  [values : (__tl_dyn-array ir.CompilerIrValue)]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (array-length values))
    (compiler-live-set-empty)
    (compiler-live-value-vars-into
      (compiler-live-call-args-array-vars values (+ index 1))
      (array-ref values index))))

(define (compiler-live-call-args-vars [args : ir.CompilerIrCallArgs]) : CompilerLiveI64Set
  (match args
    [(ir.CompilerIrCallArgs.Nil) (compiler-live-set-empty)]
    [(ir.CompilerIrCallArgs.One value) (compiler-live-value-vars value)]
    [(ir.CompilerIrCallArgs.Two a b) (compiler-live-values2-vars a b)]
    [(ir.CompilerIrCallArgs.Array values)
      (compiler-live-call-args-array-vars values 0)]))

(define (compiler-live-spmd-call-args-seq-vars
  [seq : ir.CompilerIrSpmdCallArgSeq]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (struct-get seq len))
    (compiler-live-set-empty)
    (match (array-ref (struct-get seq slots) index)
      [(ir.CompilerIrSpmdCallArg.Arg _ value _)
        (compiler-live-value-vars-into
          (compiler-live-spmd-call-args-seq-vars seq (+ index 1))
          value)])))

(define (compiler-live-spmd-call-args-vars
  [args : ir.CompilerIrSpmdCallArgList]) : CompilerLiveI64Set
  (match args
    [(ir.CompilerIrSpmdCallArgList.Nil) (compiler-live-set-empty)]
    [(ir.CompilerIrSpmdCallArgList.Cons arg rest)
      (match arg
        [(ir.CompilerIrSpmdCallArg.Arg _ value _)
          (compiler-live-value-vars-into
            (compiler-live-spmd-call-args-vars (box-get rest))
            value)])]
    [(ir.CompilerIrSpmdCallArgList.Array seq)
      (compiler-live-spmd-call-args-seq-vars seq 0)]))

(define (compiler-live-maybe-value-vars [value : ir.CompilerIrMaybeValue]) : CompilerLiveI64Set
  (match value
    [(ir.CompilerIrMaybeValue.No) (compiler-live-set-empty)]
    [(ir.CompilerIrMaybeValue.Some inner) (compiler-live-value-vars inner)]))

(define (compiler-live-phi-input-vars [inputs : ir.CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match (ir.compiler-ir-phi-input-list-force-cons inputs)
    [(ir.CompilerIrPhiInputList.Nil) (compiler-live-set-empty)]
    [(ir.CompilerIrPhiInputList.Array seq)
      (compiler-live-phi-input-vars (ir.compiler-ir-phi-input-seq-to-list seq))]
    [(ir.CompilerIrPhiInputList.Cons value _ rest)
      (compiler-live-value-vars-into
        (compiler-live-phi-input-vars (box-get rest))
        value)]))

(define (compiler-live-switch-case-successors
  [set : CompilerLiveLabelSet]
  [cases : ir.CompilerIrSwitchCaseList]) : CompilerLiveLabelSet
  (match cases
    [(ir.CompilerIrSwitchCaseList.Nil) set]
    [(ir.CompilerIrSwitchCaseList.Cons case rest)
      (match case
        [(ir.CompilerIrSwitchCase.Case _ label)
          (compiler-live-switch-case-successors
            (compiler-live-label-set-insert set label)
            (box-get rest))])]
    [(ir.CompilerIrSwitchCaseList.Array seq)
      (compiler-live-switch-case-successors
        set
        (ir.compiler-ir-switch-case-seq-to-list seq))]))

(define (compiler-live-instr-uses [instr : ir.CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(ir.CompilerIrInstr.Mov _ src _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.Alloc _ _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.AddrOf _ src) (compiler-live-set1 src)]
    [(ir.CompilerIrInstr.Gep _ base offset _)
      (compiler-live-values2-vars base offset)]
    [(ir.CompilerIrInstr.Load _ src _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.StorePtr dst src _)
      (compiler-live-values2-vars dst src)]
    [(ir.CompilerIrInstr.CopyBytes dst src _)
      (compiler-live-values2-vars dst src)]
    [(ir.CompilerIrInstr.BoundsCheck index length _)
      (compiler-live-values2-vars index length)]
    [(ir.CompilerIrInstr.Cast _ src _ _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.Bitcast _ src _ _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.BinOp _ _ lhs rhs _)
      (compiler-live-values2-vars lhs rhs)]
    [(ir.CompilerIrInstr.UnOp _ _ src _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.LaneId _ _ _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.Splat _ value _ _) (compiler-live-value-vars value)]
    [(ir.CompilerIrInstr.VectorBinOp payload-box)
      (let
        [lhs (struct-get (box-get payload-box) lhs)]
        [rhs (struct-get (box-get payload-box) rhs)]
        (compiler-live-values2-vars lhs rhs))]
    [(ir.CompilerIrInstr.VectorPrefix payload-box)
      (let
        [src (struct-get (box-get payload-box) src)]
        [carry (struct-get (box-get payload-box) carry)]
        (compiler-live-values2-vars src carry))]
    [(ir.CompilerIrInstr.VectorReduce _ _ src _ _)
      (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.VectorCompare payload-box)
      (let
        [lhs (struct-get (box-get payload-box) lhs)]
        [rhs (struct-get (box-get payload-box) rhs)]
        (compiler-live-values2-vars lhs rhs))]
    [(ir.CompilerIrInstr.MaskBinOp _ _ lhs rhs _)
      (compiler-live-values2-vars lhs rhs)]
    [(ir.CompilerIrInstr.MaskNot _ src _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.MaskReduce _ _ src _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.Select payload-box)
      (let
        [mask (struct-get (box-get payload-box) mask)]
        [on-true (struct-get (box-get payload-box) on-true)]
        [on-false (struct-get (box-get payload-box) on-false)]
        (compiler-live-values3-vars mask on-true on-false))]
    [(ir.CompilerIrInstr.VectorLoad _ base index _ _)
      (compiler-live-values2-vars base index)]
    [(ir.CompilerIrInstr.VectorStore payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [value (struct-get (box-get payload-box) value)]
        (compiler-live-values3-vars base index value))]
    [(ir.CompilerIrInstr.PredicatedStore payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [value (struct-get (box-get payload-box) value)]
        [mask (struct-get (box-get payload-box) mask)]
        (compiler-live-values4-vars base index value mask))]
    [(ir.CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index (struct-get (box-get payload-box) index)]
        [mask (struct-get (box-get payload-box) mask)]
        (compiler-live-values3-vars base index mask))]
    [(ir.CompilerIrInstr.GatherLoad payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [index-base (struct-get (box-get payload-box) index-base)]
        [index (struct-get (box-get payload-box) index)]
        (compiler-live-values3-vars base index-base index))]
    [(ir.CompilerIrInstr.VectorShuffle payload-box)
      (let
        [source (struct-get (box-get payload-box) source)]
        [selector-low (struct-get (box-get payload-box) selector-low)]
        [selector-high (struct-get (box-get payload-box) selector-high)]
        [active-lanes (struct-get (box-get payload-box) active-lanes)]
        (compiler-live-set-union
          (compiler-live-values3-vars source selector-low active-lanes)
          (compiler-live-maybe-value-vars selector-high)))]
    [(ir.CompilerIrInstr.TailMask _ index len _)
      (compiler-live-values2-vars index len)]
    [(ir.CompilerIrInstr.EntryArgc _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.EntryArgv _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.EntryEnvp _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.CpuId _ leaf subleaf _)
      (compiler-live-values2-vars leaf subleaf)]
    [(ir.CompilerIrInstr.Xgetbv _ index) (compiler-live-value-vars index)]
    [(ir.CompilerIrInstr.Syscall _ args) (compiler-live-call-args-vars args)]
    [(ir.CompilerIrInstr.Call _ _ args _) (compiler-live-call-args-vars args)]
    [(ir.CompilerIrInstr.CallIndirect _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(ir.CompilerIrInstr.CallIndirectC _ func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(ir.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into (compiler-live-call-args-vars args) base))]
    [(ir.CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (let
        [base (struct-get (box-get payload-box) base)]
        [func (struct-get (box-get payload-box) callee)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into
          (compiler-live-value-vars-into
            (compiler-live-call-args-vars args)
            base)
          func))]
    [(ir.CompilerIrInstr.SpmdCall payload-box)
      (let
        [active-mask (struct-get (box-get payload-box) active-mask)]
        [args (struct-get (box-get payload-box) args)]
        (compiler-live-value-vars-into
          (compiler-live-spmd-call-args-vars args)
          active-mask))]
    [(ir.CompilerIrInstr.TailCall _ args _) (compiler-live-call-args-vars args)]
    [(ir.CompilerIrInstr.Store _ value _) (compiler-live-value-vars value)]
    [(ir.CompilerIrInstr.Branch cond _ _) (compiler-live-value-vars cond)]
    [(ir.CompilerIrInstr.TotalEnumBranch cond _ _)
      (compiler-live-value-vars cond)]
    [(ir.CompilerIrInstr.Return value) (compiler-live-maybe-value-vars value)]
    [(ir.CompilerIrInstr.Phi _ inputs _) (compiler-live-phi-input-vars inputs)]
    [(ir.CompilerIrInstr.Pack _ words _) (compiler-live-value-list-vars words)]
    [(ir.CompilerIrInstr.Word _ src _ _) (compiler-live-value-vars src)]
    [(ir.CompilerIrInstr.Jump _) (compiler-live-set-empty)]
    [(ir.CompilerIrInstr.TailCallIndirect func args _)
      (compiler-live-value-vars-into (compiler-live-call-args-vars args) func)]
    [(ir.CompilerIrInstr.Switch index _ _ _) (compiler-live-value-vars index)]
    [(ir.CompilerIrInstr.TotalEnumSwitch index _ _ _ _)
      (compiler-live-value-vars index)]))

;; ---------------------------------------------------------------------------
;; Direct per-instruction var-id extraction.
;;
;; An instruction names one def and (almost always) one to three uses, but
;; CompilerLiveI64Set is keyed by ABSOLUTE var id: `(compiler-live-set1 v)`
;; allocates `v / 32 + 1` words to carry a single bit, and every consumer then
;; scans those words to recover the id the instruction constructor already
;; holds. The set is the right shape for BLOCK facts (live-in/out are genuinely
;; dense and get unioned/subtracted), but for the per-instruction step the
;; allocation and the word scan are both pure overhead.
;;
;; These entry points hand the ids over directly:
;;   * `compiler-live-instr-def-var` -- the single defined var, or -1.
;;   * `compiler-live-instr-use-ids-into!` -- the DISTINCT used var ids written
;;     into a caller-owned scratch array, or -1 when they do not fit.
;; Both are exact mirrors of `compiler-live-instr-defs` / `-uses`: same arms,
;; same operands, same de-duplication, so `{ids} == set` element-wise. Order is
;; operand order rather than the set's ascending id order, which is why
;; order-sensitive consumers (remat's var renumbering) keep the bitset.
;; ---------------------------------------------------------------------------
;; The single var an instruction defines, or -1. Mirrors compiler-live-instr-defs
;; arm for arm (compiler_regalloc's compiler-reg-instr-def-var is the same
;; function over the same arms, kept there for the def census).
(define (compiler-live-instr-def-var [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(ir.CompilerIrInstr.Mov dst _ _) dst]
    [(ir.CompilerIrInstr.Alloc dst _) dst]
    [(ir.CompilerIrInstr.AddrOf dst _) dst]
    [(ir.CompilerIrInstr.Gep dst _ _ _) dst]
    [(ir.CompilerIrInstr.Load dst _ _) dst]
    [(ir.CompilerIrInstr.Cast dst _ _ _) dst]
    [(ir.CompilerIrInstr.Bitcast dst _ _ _) dst]
    [(ir.CompilerIrInstr.BinOp dst _ _ _ _) dst]
    [(ir.CompilerIrInstr.UnOp dst _ _ _) dst]
    [(ir.CompilerIrInstr.LaneId dst _ _) dst]
    [(ir.CompilerIrInstr.Splat dst _ _ _) dst]
    [(ir.CompilerIrInstr.VectorBinOp payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.VectorPrefix payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.VectorReduce dst _ _ _ _) dst]
    [(ir.CompilerIrInstr.VectorCompare payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.MaskBinOp dst _ _ _ _) dst]
    [(ir.CompilerIrInstr.MaskNot dst _ _) dst]
    [(ir.CompilerIrInstr.MaskReduce dst _ _ _) dst]
    [(ir.CompilerIrInstr.Select payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.VectorLoad dst _ _ _ _) dst]
    [(ir.CompilerIrInstr.PredicatedLoad payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.GatherLoad payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.VectorShuffle payload-box)
      (struct-get (box-get payload-box) dst)]
    [(ir.CompilerIrInstr.TailMask dst _ _ _) dst]
    [(ir.CompilerIrInstr.EntryArgc dst) dst]
    [(ir.CompilerIrInstr.EntryArgv dst) dst]
    [(ir.CompilerIrInstr.EntryEnvp dst) dst]
    [(ir.CompilerIrInstr.CpuId dst _ _ _) dst]
    [(ir.CompilerIrInstr.Xgetbv dst _) dst]
    [(ir.CompilerIrInstr.Syscall dst _) dst]
    [(ir.CompilerIrInstr.Call dst _ _ _) dst]
    [(ir.CompilerIrInstr.CallIndirect dst _ _ _) dst]
    [(ir.CompilerIrInstr.CallIndirectC dst _ _ _) dst]
    [(ir.CompilerIrInstr.SpmdCall payload-box)
      (match (struct-get (box-get payload-box) result)
        [(ir.CompilerIrSpmdCallResult.Unit) -1]
        [(ir.CompilerIrSpmdCallResult.Value dst _ _) dst])]
    [(ir.CompilerIrInstr.Phi dst _ _) dst]
    [(ir.CompilerIrInstr.Pack dst _ _) dst]
    [(ir.CompilerIrInstr.Word dst _ _ _) dst]
    [_ -1]))

;; Append `id` to `out[0..n)` unless it is already there (the bitset de-dups,
;; so `x = x + x` must yield one id, not two). Negative ids are dropped exactly
;; as compiler-live-set-builder-insert! drops them. Returns the new count, or
;; -1 once the ids no longer fit; -1 is sticky so an overflow survives the rest
;; of the walk and the caller falls back to the bitset.
(define (compiler-live-use-ids-push!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [id : i64]) : i64
  (if (< n 0)
    -1
    (if (< id 0)
      n
      (let
        [index : i64 0]
        [found : bool false]
        (begin
          (while (and (< index n) (not found))
            (begin
              (if (= (array-ref out index) id)
                (set! found true)
                unit)
              (set! index (+ index 1))))
          (if found
            n
            (if (>= n (array-length out))
              -1
              (begin
                (array-set! out n id)
                (+ n 1)))))))))

(define (compiler-live-use-ids-add-value!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [value : ir.CompilerIrValue]) : i64
  (match value
    [(ir.CompilerIrValue.Var id) (compiler-live-use-ids-push! out n id)]
    [_ n]))

(define (compiler-live-use-ids-add-maybe-value!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [value : ir.CompilerIrMaybeValue]) : i64
  (match value
    [(ir.CompilerIrMaybeValue.No) n]
    [(ir.CompilerIrMaybeValue.Some inner)
      (compiler-live-use-ids-add-value! out n inner)]))

(define (compiler-live-use-ids-add-value-array!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [values : (Array ir.CompilerIrValue)]
  [index : i64]) : i64
  (if (>= index (array-length values))
    n
    (compiler-live-use-ids-add-value-array!
      out
      (compiler-live-use-ids-add-value! out n (array-ref values index))
      values
      (+ index 1))))

(define (compiler-live-use-ids-add-call-args!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [args : ir.CompilerIrCallArgs]) : i64
  (match args
    [(ir.CompilerIrCallArgs.Nil) n]
    [(ir.CompilerIrCallArgs.One value)
      (compiler-live-use-ids-add-value! out n value)]
    [(ir.CompilerIrCallArgs.Two a b)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out n a)
        b)]
    [(ir.CompilerIrCallArgs.Array values)
      (compiler-live-use-ids-add-value-array! out n values 0)]))

;; Walk the seq/list value forms in place. The bitset path reaches these through
;; `compiler-ir-value-list-force-cons`, which MATERIALIZES a cons list (one box
;; per element) for the array representation before reading it; walking the
;; slots directly drops that per-instruction list build as well.
(define (compiler-live-use-ids-add-value-seq!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [seq : ir.CompilerIrValueSeq]
  [index : i64]) : i64
  (if (>= index (struct-get seq len))
    n
    (compiler-live-use-ids-add-value-seq!
      out
      (compiler-live-use-ids-add-value!
        out
        n
        (array-ref (struct-get seq slots) index))
      seq
      (+ index 1))))

(define (compiler-live-use-ids-add-value-list!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [values : ir.CompilerIrValueList]) : i64
  (match values
    [(ir.CompilerIrValueList.Nil) n]
    [(ir.CompilerIrValueList.Array seq)
      (compiler-live-use-ids-add-value-seq! out n seq 0)]
    [(ir.CompilerIrValueList.Cons value rest)
      (compiler-live-use-ids-add-value-list!
        out
        (compiler-live-use-ids-add-value! out n value)
        (box-get rest))]))

(define (compiler-live-use-ids-add-phi-input-seq!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [seq : ir.CompilerIrPhiInputSeq]
  [index : i64]) : i64
  (if (>= index (struct-get seq len))
    n
    (compiler-live-use-ids-add-phi-input-seq!
      out
      (compiler-live-use-ids-add-value!
        out
        n
        (struct-get (array-ref (struct-get seq slots) index) value))
      seq
      (+ index 1))))

(define (compiler-live-use-ids-add-phi-inputs!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [inputs : ir.CompilerIrPhiInputList]) : i64
  (match inputs
    [(ir.CompilerIrPhiInputList.Nil) n]
    [(ir.CompilerIrPhiInputList.Array seq)
      (compiler-live-use-ids-add-phi-input-seq! out n seq 0)]
    [(ir.CompilerIrPhiInputList.Cons value _ rest)
      (compiler-live-use-ids-add-phi-inputs!
        out
        (compiler-live-use-ids-add-value! out n value)
        (box-get rest))]))

(define (compiler-live-use-ids-add-spmd-args-seq!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [seq : ir.CompilerIrSpmdCallArgSeq]
  [index : i64]) : i64
  (if (>= index (struct-get seq len))
    n
    (compiler-live-use-ids-add-spmd-args-seq!
      out
      (match (array-ref (struct-get seq slots) index)
        [(ir.CompilerIrSpmdCallArg.Arg _ value _)
          (compiler-live-use-ids-add-value! out n value)])
      seq
      (+ index 1))))

(define (compiler-live-use-ids-add-spmd-args!
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [args : ir.CompilerIrSpmdCallArgList]) : i64
  (match args
    [(ir.CompilerIrSpmdCallArgList.Nil) n]
    [(ir.CompilerIrSpmdCallArgList.Array seq)
      (compiler-live-use-ids-add-spmd-args-seq! out n seq 0)]
    [(ir.CompilerIrSpmdCallArgList.Cons arg rest)
      (compiler-live-use-ids-add-spmd-args!
        out
        (match arg
          [(ir.CompilerIrSpmdCallArg.Arg _ value _)
            (compiler-live-use-ids-add-value! out n value)])
        (box-get rest))]))

;; Write the distinct used var ids of `instr` into `out`, returning the count,
;; or -1 when they do not fit (caller falls back to compiler-live-instr-uses).
;; Arm for arm this is compiler-live-instr-uses with `compiler-live-set*`
;; replaced by `push!`.
(define (compiler-live-instr-use-ids-into!
  [instr : ir.CompilerIrInstr]
  [out : (__tl_dyn-array i64)]) : i64
  (match instr
    [(ir.CompilerIrInstr.Mov _ src _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.Alloc _ _) 0]
    [(ir.CompilerIrInstr.AddrOf _ src) (compiler-live-use-ids-push! out 0 src)]
    [(ir.CompilerIrInstr.Gep _ base offset _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 base)
        offset)]
    [(ir.CompilerIrInstr.Load _ src _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.StorePtr dst src _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 dst)
        src)]
    [(ir.CompilerIrInstr.CopyBytes dst src _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 dst)
        src)]
    [(ir.CompilerIrInstr.BoundsCheck index length _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 index)
        length)]
    [(ir.CompilerIrInstr.Cast _ src _ _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.Bitcast _ src _ _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.BinOp _ _ lhs rhs _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 lhs)
        rhs)]
    [(ir.CompilerIrInstr.UnOp _ _ src _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.LaneId _ _ _) 0]
    [(ir.CompilerIrInstr.Splat _ value _ _)
      (compiler-live-use-ids-add-value! out 0 value)]
    [(ir.CompilerIrInstr.VectorBinOp payload-box)
      (let
        [payload : ir.CompilerIrInstrVectorBinOpPayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value! out 0 (struct-get payload lhs))
          (struct-get payload rhs)))]
    [(ir.CompilerIrInstr.VectorPrefix payload-box)
      (let
        [payload : ir.CompilerIrInstrVectorPrefixPayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value! out 0 (struct-get payload src))
          (struct-get payload carry)))]
    [(ir.CompilerIrInstr.VectorReduce _ _ src _ _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.VectorCompare payload-box)
      (let
        [payload : ir.CompilerIrInstrVectorComparePayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value! out 0 (struct-get payload lhs))
          (struct-get payload rhs)))]
    [(ir.CompilerIrInstr.MaskBinOp _ _ lhs rhs _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 lhs)
        rhs)]
    [(ir.CompilerIrInstr.MaskNot _ src _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.MaskReduce _ _ src _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.Select payload-box)
      (let
        [payload : ir.CompilerIrInstrSelectPayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value! out 0 (struct-get payload mask))
            (struct-get payload on-true))
          (struct-get payload on-false)))]
    [(ir.CompilerIrInstr.VectorLoad _ base index _ _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 base)
        index)]
    [(ir.CompilerIrInstr.VectorStore payload-box)
      (let
        [payload : ir.CompilerIrInstrVectorStorePayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value! out 0 (struct-get payload base))
            (struct-get payload index))
          (struct-get payload value)))]
    [(ir.CompilerIrInstr.PredicatedStore payload-box)
      (let
        [payload : ir.CompilerIrInstrPredicatedStorePayload
          (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value!
              out
              (compiler-live-use-ids-add-value! out 0 (struct-get payload base))
              (struct-get payload index))
            (struct-get payload value))
          (struct-get payload mask)))]
    [(ir.CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [payload : ir.CompilerIrInstrPredicatedLoadPayload
          (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value! out 0 (struct-get payload base))
            (struct-get payload index))
          (struct-get payload mask)))]
    [(ir.CompilerIrInstr.GatherLoad payload-box)
      (let
        [payload : ir.CompilerIrInstrGatherLoadPayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value! out 0 (struct-get payload base))
            (struct-get payload index-base))
          (struct-get payload index)))]
    [(ir.CompilerIrInstr.VectorShuffle payload-box)
      (let
        [payload : ir.CompilerIrInstrVectorShufflePayload (box-get payload-box)]
        (compiler-live-use-ids-add-maybe-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-value!
              out
              (compiler-live-use-ids-add-value!
                out
                0
                (struct-get payload source))
              (struct-get payload selector-low))
            (struct-get payload active-lanes))
          (struct-get payload selector-high)))]
    [(ir.CompilerIrInstr.TailMask _ index len _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 index)
        len)]
    [(ir.CompilerIrInstr.EntryArgc _) 0]
    [(ir.CompilerIrInstr.EntryArgv _) 0]
    [(ir.CompilerIrInstr.EntryEnvp _) 0]
    [(ir.CompilerIrInstr.CpuId _ leaf subleaf _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-value! out 0 leaf)
        subleaf)]
    [(ir.CompilerIrInstr.Xgetbv _ index)
      (compiler-live-use-ids-add-value! out 0 index)]
    [(ir.CompilerIrInstr.Syscall _ args)
      (compiler-live-use-ids-add-call-args! out 0 args)]
    [(ir.CompilerIrInstr.Call _ _ args _)
      (compiler-live-use-ids-add-call-args! out 0 args)]
    [(ir.CompilerIrInstr.CallIndirect _ func args _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-call-args! out 0 args)
        func)]
    [(ir.CompilerIrInstr.CallIndirectC _ func args _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-call-args! out 0 args)
        func)]
    [(ir.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [payload : ir.CompilerIrInstrCallCAbiStoreResultPayload
          (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-call-args! out 0 (struct-get payload args))
          (struct-get payload base)))]
    [(ir.CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (let
        [payload : ir.CompilerIrInstrCallIndirectCAbiStoreResultPayload
          (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-value!
            out
            (compiler-live-use-ids-add-call-args!
              out
              0
              (struct-get payload args))
            (struct-get payload base))
          (struct-get payload callee)))]
    [(ir.CompilerIrInstr.SpmdCall payload-box)
      (let
        [payload : ir.CompilerIrInstrSpmdCallPayload (box-get payload-box)]
        (compiler-live-use-ids-add-value!
          out
          (compiler-live-use-ids-add-spmd-args! out 0 (struct-get payload args))
          (struct-get payload active-mask)))]
    [(ir.CompilerIrInstr.TailCall _ args _)
      (compiler-live-use-ids-add-call-args! out 0 args)]
    [(ir.CompilerIrInstr.Store _ value _)
      (compiler-live-use-ids-add-value! out 0 value)]
    [(ir.CompilerIrInstr.Branch cond _ _)
      (compiler-live-use-ids-add-value! out 0 cond)]
    [(ir.CompilerIrInstr.TotalEnumBranch cond _ _)
      (compiler-live-use-ids-add-value! out 0 cond)]
    [(ir.CompilerIrInstr.Return value)
      (compiler-live-use-ids-add-maybe-value! out 0 value)]
    [(ir.CompilerIrInstr.Phi _ inputs _)
      (compiler-live-use-ids-add-phi-inputs! out 0 inputs)]
    [(ir.CompilerIrInstr.Pack _ words _)
      (compiler-live-use-ids-add-value-list! out 0 words)]
    [(ir.CompilerIrInstr.Word _ src _ _)
      (compiler-live-use-ids-add-value! out 0 src)]
    [(ir.CompilerIrInstr.Jump _) 0]
    [(ir.CompilerIrInstr.TailCallIndirect func args _)
      (compiler-live-use-ids-add-value!
        out
        (compiler-live-use-ids-add-call-args! out 0 args)
        func)]
    [(ir.CompilerIrInstr.Switch index _ _ _)
      (compiler-live-use-ids-add-value! out 0 index)]
    [(ir.CompilerIrInstr.TotalEnumSwitch index _ _ _ _)
      (compiler-live-use-ids-add-value! out 0 index)]))

;; Edge-precise counterpart of compiler-live-instr-use-ids-into!: a phi's inputs
;; are edge uses, so the phi point itself uses nothing.
(define (compiler-live-instr-use-ids-nophi-into!
  [instr : ir.CompilerIrInstr]
  [out : (__tl_dyn-array i64)]) : i64
  (match instr
    [(ir.CompilerIrInstr.Phi _ _ _) 0]
    [_ (compiler-live-instr-use-ids-into! instr out)]))

;; One shared extraction buffer. Every consumer extracts the ids and consumes
;; them in the same leaf loop, and no such loop starts a second extraction, so a
;; single buffer serves all of them and no caller has to thread a scratch array
;; down the liveness / interval / ref-count call chains. Hold the ids only until
;; the next `compiler-live-instr-use-ids!` call.
;;
;; 64 slots: an opt2 self-compile decodes 15,877,540 use lists whose widest is a
;; 17..64-id call/phi (1,571 of them) and never exceeds 64; a wider one simply
;; returns -1 and the caller takes the bitset path, so capacity is a throughput
;; choice, not a correctness one.
(define compiler-live-instr-ids-buffer : (__tl_dyn-array i64)
  (make-array i64 64))

(define (compiler-live-instr-ids) : (__tl_dyn-array i64)
  compiler-live-instr-ids-buffer)

(define (compiler-live-instr-use-ids! [instr : ir.CompilerIrInstr]) : i64
  (compiler-live-instr-use-ids-into! instr compiler-live-instr-ids-buffer))

(define (compiler-live-instr-use-ids-nophi! [instr : ir.CompilerIrInstr]) : i64
  (compiler-live-instr-use-ids-nophi-into! instr compiler-live-instr-ids-buffer))

;; Word count of the bitset the ids would have produced: the widest id decides
;; it, exactly as `compiler-live-set-word-count` reads it off a set whose top
;; word is nonzero by construction.
(define (compiler-live-use-ids-word-count
  [ids : (__tl_dyn-array i64)]
  [id-count : i64]) : i64
  (let
    [index : i64 0]
    [words : i64 0]
    (begin
      (while (< index id-count)
        (begin
          (set!
            words
            (compiler-live-set-max
              words
              (+ (compiler-live-set-word-index (array-ref ids index)) 1)))
          (set! index (+ index 1))))
      words)))

(define (compiler-live-var-word-count-of [var : i64]) : i64
  (if (< var 0)
    0
    (+ (compiler-live-set-word-index var) 1)))

(define (compiler-live-instr-defs [instr : ir.CompilerIrInstr]) : CompilerLiveI64Set
  (let
    [dst : i64 (compiler-live-instr-def-var instr)]
    (if (< dst 0)
      (compiler-live-set-empty)
      (compiler-live-set1 dst))))

(define (compiler-live-block-use-def-instrs
  [instrs : ir.CompilerIrInstrList]
  [uses : CompilerLiveI64Set]
  [defs : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(ir.CompilerIrInstrList.Nil) (CompilerLiveUseDef uses defs)]
    [(ir.CompilerIrInstrList.Cons instr rest)
      (let
        [instr-uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
        [instr-defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
        (compiler-live-block-use-def-instrs
          (box-get rest)
          (compiler-live-set-union
            uses
            (compiler-live-set-minus instr-uses defs))
          (compiler-live-set-union defs instr-defs)))]))

(define (compiler-live-block-use-def [instrs : ir.CompilerIrInstrList]) : CompilerLiveUseDef
  (compiler-live-block-use-def-instrs
    instrs
    (compiler-live-set-empty)
    (compiler-live-set-empty)))

;; Id form of compiler-live-block-use-def-step!: `uses |= instr-uses & ~defs`
;; and `defs |= instr-defs`, applied one bit at a time.
;;
;; Equivalent to the word form because each use id is still tested against the
;; defs accumulated by EARLIER instructions (this instruction's def bit is set
;; only after every use has been considered), the def set holds at most one bit,
;; and setting a bit twice is idempotent, so an id list that repeats nothing --
;; `compiler-live-instr-use-ids-into!` de-duplicates -- writes exactly the bits
;; the OR of the two word arrays would have written.
(define (compiler-live-block-use-def-step-ids!
  [uses : (__tl_dyn-array i64)]
  [defs : (__tl_dyn-array i64)]
  [ids : (__tl_dyn-array i64)]
  [id-count : i64]
  [def-var : i64]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index id-count)
        (let
          [var : i64 (array-ref ids index)]
          [word : i64 (compiler-live-set-word-index var)]
          [mask : i64 (compiler-live-set-bit-mask var)]
          (begin
            (if (= (bit-and (array-ref defs word) mask) 0)
              (array-set! uses word (bit-or (array-ref uses word) mask))
              unit)
            (set! index (+ index 1)))))
      (if (< def-var 0)
        unit
        (let
          [word : i64 (compiler-live-set-word-index def-var)]
          (array-set!
            defs
            word
            (bit-or (array-ref defs word) (compiler-live-set-bit-mask def-var))))))))

(define (compiler-live-block-use-def-step!
  [uses : (__tl_dyn-array i64)]
  [defs : (__tl_dyn-array i64)]
  [instr-uses : CompilerLiveI64Set]
  [instr-defs : CompilerLiveI64Set]) : unit
  (let
    [use-data : (MutPtr i64)
      (unsafe
        (array-data uses))]
    [def-data : (MutPtr i64)
      (unsafe
        (array-data defs))]
    [instr-use-words : (__tl_dyn-array i64)
      (compiler-live-set-words instr-uses)]
    [instr-def-words : (__tl_dyn-array i64)
      (compiler-live-set-words instr-defs)]
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
  [instrs : ir.CompilerIrInstrSeq]
  [uses : (__tl_dyn-array i64)]
  [defs : (__tl_dyn-array i64)]
  [edge-precise? : bool]) : CompilerLiveUseDef
  (let
    [count : i64 (ir.compiler-ir-instr-seq-count instrs)]
    [use-count : i64 0]
    [def-count : i64 0]
    [index : i64 0]
    (begin
      (compiler-live-scratch-clear! uses)
      (compiler-live-scratch-clear! defs)
      (while (< index count)
        (let
          [instr : ir.CompilerIrInstr
            (ir.compiler-ir-instr-seq-ref instrs index)]
          [ids : (__tl_dyn-array i64) (compiler-live-instr-ids)]
          [id-count : i64
            (if edge-precise?
              (compiler-live-instr-use-ids-nophi! instr)
              (compiler-live-instr-use-ids! instr))]
          [def-var : i64 (compiler-live-instr-def-var instr)]
          (begin
            (if (< id-count 0)
              ;; Wider than the extraction buffer: take the bitset path, which
              ;; has no width limit.
              (let
                [instr-uses : CompilerLiveI64Set
                  (if edge-precise?
                    (compiler-live-instr-uses-nophi instr)
                    (compiler-live-instr-uses instr))]
                [instr-defs : CompilerLiveI64Set
                  (compiler-live-instr-defs instr)]
                (begin
                  (compiler-live-block-use-def-step!
                    uses
                    defs
                    instr-uses
                    instr-defs)
                  (set!
                    use-count
                    (compiler-live-set-max
                      use-count
                      (compiler-live-set-word-count instr-uses)))
                  (set!
                    def-count
                    (compiler-live-set-max
                      def-count
                      (compiler-live-set-word-count instr-defs)))))
              (begin
                (compiler-live-block-use-def-step-ids!
                  uses
                  defs
                  ids
                  id-count
                  def-var)
                (set!
                  use-count
                  (compiler-live-set-max
                    use-count
                    (compiler-live-use-ids-word-count ids id-count)))
                (set!
                  def-count
                  (compiler-live-set-max
                    def-count
                    (compiler-live-var-word-count-of def-var)))))
            (set! index (+ index 1)))))
      (CompilerLiveUseDef
        (compiler-live-scratch-freeze uses use-count)
        (compiler-live-scratch-freeze defs def-count)))))

(define (compiler-live-instr-seq-last [instrs : ir.CompilerIrInstrSeq]) : CompilerLiveMaybeInstr
  (if (ir.compiler-ir-instr-seq-empty? instrs)
    CompilerLiveMaybeInstr.No
    (CompilerLiveMaybeInstr.Some
      (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1)))))

(define (compiler-live-block-successors [block : ir.CompilerIrBlock]) : CompilerLiveLabelSet
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (compiler-live-instr-seq-last instrs)
        [(CompilerLiveMaybeInstr.No) CompilerLiveLabelSet.Nil]
        [(CompilerLiveMaybeInstr.Some instr)
          (match instr
            [(ir.CompilerIrInstr.Jump target)
              (compiler-live-label-set-cons target CompilerLiveLabelSet.Nil)]
            [(ir.CompilerIrInstr.Branch _ true-label false-label)
              (compiler-live-label-set-insert
                (compiler-live-label-set-cons
                  true-label
                  CompilerLiveLabelSet.Nil)
                false-label)]
            [(ir.CompilerIrInstr.TotalEnumBranch _ true-label false-label)
              (compiler-live-label-set-insert
                (compiler-live-label-set-cons
                  true-label
                  CompilerLiveLabelSet.Nil)
                false-label)]
            [(ir.CompilerIrInstr.Switch _ _ cases default-label)
              (compiler-live-switch-case-successors
                (compiler-live-label-set-cons
                  default-label
                  CompilerLiveLabelSet.Nil)
                cases)]
            [(ir.CompilerIrInstr.TotalEnumSwitch
                _
                _
                cases
                default-label
                trap-label)
              (compiler-live-switch-case-successors
                (if (= trap-label (ir.compiler-ir-label-none))
                  (compiler-live-label-set-cons
                    default-label
                    CompilerLiveLabelSet.Nil)
                  (compiler-live-label-set-insert
                    (compiler-live-label-set-cons
                      default-label
                      CompilerLiveLabelSet.Nil)
                    trap-label))
                cases)]
            [_ CompilerLiveLabelSet.Nil])])]))

(define (compiler-live-build-block-from-use-def
  [block : ir.CompilerIrBlock]
  [use-def : CompilerLiveUseDef]) : CompilerLiveBlock
  (match block
    [(ir.CompilerIrBlock.Block label _)
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
  [items : (__tl_dyn-array i64)]
  [count : i64]) : (__tl_dyn-array i64)
  (if (= count (array-length items))
    items
    (let
      [out : (__tl_dyn-array i64) (make-array i64 count)]
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
  [items : (__tl_dyn-array i64)]
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
    [items : (__tl_dyn-array i64)
      (make-array i64 (compiler-live-label-set-count labels))]
    [count : i64 (compiler-live-label-set-fill-indexes! labels ids items 0)]
    (CompilerLiveIndexVec (compiler-live-i64-array-prefix-copy items count))))

;; Precompute reverse CFG edges once. The worklist below only reprocesses
;; predecessors of a changed block, preserving deterministic source/RPO order.
(define (compiler-live-predecessor-counts-add!
  [successors : (__tl_dyn-array CompilerLiveIndexVec)]
  [counts : (__tl_dyn-array i64)]
  [source : i64]) : unit
  (if (>= source (array-length successors))
    unit
    (let
      [items : (__tl_dyn-array i64)
        (struct-get (array-ref successors source) items)]
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
  [counts : (__tl_dyn-array i64)]
  [index : i64]
  [out : (__tl_dyn-array CompilerLiveIndexVec)]) : unit
  (if (>= index (array-length counts))
    unit
    (begin
      (array-set!
        out
        index
        (CompilerLiveIndexVec (make-array i64 (array-ref counts index))))
      (compiler-live-predecessor-items-make counts (+ index 1) out))))

(define (compiler-live-predecessor-fill!
  [successors : (__tl_dyn-array CompilerLiveIndexVec)]
  [predecessors : (__tl_dyn-array CompilerLiveIndexVec)]
  [next : (__tl_dyn-array i64)]
  [source : i64]) : unit
  (if (>= source (array-length successors))
    unit
    (let
      [items : (__tl_dyn-array i64)
        (struct-get (array-ref successors source) items)]
      [i : i64 0]
      (begin
        (while (< i (array-length items))
          (let
            [target : i64 (array-ref items i)]
            [slot : i64 (array-ref next target)]
            [target-items : (__tl_dyn-array i64)
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
  [successors : (__tl_dyn-array CompilerLiveIndexVec)]) : (__tl_dyn-array
    CompilerLiveIndexVec)
  (let
    [count : i64 (array-length successors)]
    [counts : (__tl_dyn-array i64) (make-array i64 count)]
    [out : (__tl_dyn-array CompilerLiveIndexVec)
      (make-array CompilerLiveIndexVec count)]
    [next : (__tl_dyn-array i64) (make-array i64 count)]
    (begin
      (compiler-live-predecessor-counts-add! successors counts 0)
      (compiler-live-predecessor-items-make counts 0 out)
      (compiler-live-predecessor-fill! successors out next 0)
      out)))

(define (compiler-live-successor-live-out-graph-into!
  [successors : CompilerLiveIndexVec]
  [graph : CompilerLiveBlockGraph]
  [words : (__tl_dyn-array i64)]) : i64
  (let
    [items : (__tl_dyn-array i64) (struct-get successors items)]
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
  [words : (__tl_dyn-array i64)]) : CompilerLiveBlock
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

(define (compiler-live-worklist-seed!
  [pending : (__tl_dyn-array bool)]
  [index : i64]) : unit
  (if (>= index (array-length pending))
    unit
    (begin
      (array-set! pending index true)
      (compiler-live-worklist-seed! pending (+ index 1)))))

;; Blocks are laid out in the lowering's deterministic reverse-postorder. For
;; backward liveness, consume that order backwards; changed facts flow only to
;; predecessor blocks, which are re-enqueued at most once while pending.
(define (compiler-live-worklist-pick! [pending : (__tl_dyn-array bool)]) : i64
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
  [pending : (__tl_dyn-array bool)]) : unit
  (let
    [items : (__tl_dyn-array i64)
      (struct-get (array-ref (struct-get graph predecessors) slot) items)]
    [i : i64 0]
    (while (< i (array-length items))
      (begin
        (array-set! pending (array-ref items i) true)
        (set! i (+ i 1))))))

(define (compiler-live-instr-seq-fill-after!
  [instrs : ir.CompilerIrInstrSeq]
  [live-out : CompilerLiveI64Set]
  [out : (__tl_dyn-array CompilerLiveI64Set)]
  [words : (__tl_dyn-array i64)]
  [edge-precise? : bool]) : unit
  (let
    [count : i64 (ir.compiler-ir-instr-seq-count instrs)]
    [index : i64 (- count 1)]
    [at-live-out? : bool true]
    [active-count : i64 (compiler-live-scratch-copy-set! words live-out)]
    (while (>= index 0)
      (let
        [instr : ir.CompilerIrInstr (ir.compiler-ir-instr-seq-ref instrs index)]
        [ids : (__tl_dyn-array i64) (compiler-live-instr-ids)]
        [id-count : i64
          (if edge-precise?
            (compiler-live-instr-use-ids-nophi! instr)
            (compiler-live-instr-use-ids! instr))]
        [def-var : i64 (compiler-live-instr-def-var instr)]
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
            (if (< id-count 0)
              (compiler-live-scratch-step!
                words
                active-count
                (if edge-precise?
                  (compiler-live-instr-uses-nophi instr)
                  (compiler-live-instr-uses instr))
                (compiler-live-instr-defs instr))
              (compiler-live-scratch-step-ids!
                words
                active-count
                ids
                id-count
                def-var)))
          (set! index (- index 1)))))))

(define (compiler-live-fill-instr-after-block
  [ir-block : ir.CompilerIrBlock]
  [block : CompilerLiveBlock]
  [words : (__tl_dyn-array i64)]
  [edge-precise? : bool]) : CompilerLiveBlock
  (match ir-block
    [(ir.CompilerIrBlock.Block _ instrs)
      (let
        [items : (__tl_dyn-array CompilerLiveI64Set)
          (make-array
            CompilerLiveI64Set
            (ir.compiler-ir-instr-seq-count instrs))]
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

(define (compiler-live-analyze-function [func : ir.CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [seq : ir.CompilerIrBlockSeq
          (compiler-live-ir-block-list-to-seq blocks)]
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
(define (compiler-live-instr-uses-nophi [instr : ir.CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(ir.CompilerIrInstr.Phi _ _ _) (compiler-live-set-empty)]
    [_ (compiler-live-instr-uses instr)]))

;; Accumulate every phi input (V, predLabel) of one phi into phi-out[ids[predLabel]].
(define (compiler-live-phi-out-add-inputs!
  [inputs : ir.CompilerIrPhiInputList]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (__tl_dyn-array CompilerLiveI64Set)]) : unit
  (match (ir.compiler-ir-phi-input-list-force-cons inputs)
    [(ir.CompilerIrPhiInputList.Nil) unit]
    [(ir.CompilerIrPhiInputList.Array seq)
      (compiler-live-phi-out-add-inputs!
        (ir.compiler-ir-phi-input-seq-to-list seq)
        ids
        phi-out)]
    [(ir.CompilerIrPhiInputList.Cons value label rest)
      (begin
        (match value
          [(ir.CompilerIrValue.Var v)
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
  [instrs : ir.CompilerIrInstrSeq]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (__tl_dyn-array CompilerLiveI64Set)]) : unit
  (let
    [count : i64 (ir.compiler-ir-instr-seq-count instrs)]
    [i : i64 0]
    (while (< i count)
      (begin
        (match (& (array-ref (struct-get instrs slots) i))
          [(ir.CompilerIrInstr.Phi _ _ _)
            (match (ir.compiler-ir-instr-seq-ref instrs i)
              [(ir.CompilerIrInstr.Phi _ inputs _)
                (compiler-live-phi-out-add-inputs! inputs ids phi-out)]
              [_ unit])]
          [_ unit])
        (set! i (+ i 1))))))

(define (compiler-live-recompute-block-graph-ep
  [block : CompilerLiveBlock]
  [graph : CompilerLiveBlockGraph]
  [index : i64]
  [phi-out : (__tl_dyn-array CompilerLiveI64Set)]
  [words : (__tl_dyn-array i64)]) : CompilerLiveBlock
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
  [phi-out : (__tl_dyn-array CompilerLiveI64Set)]
  [word-count : i64]) : CompilerLiveBlockGraph
  (let
    [blocks : (__tl_dyn-array CompilerLiveBlock) (struct-get graph blocks)]
    [pending : (__tl_dyn-array bool)
      (make-array bool (array-length (struct-get graph blocks)))]
    [words : (__tl_dyn-array i64) (make-array i64 word-count)]
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
  [blocks : ir.CompilerIrBlockList]
  [vars : i64]) : CompilerFunctionLiveness
  (let
    [seq : ir.CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
    [word-count : i64 (compiler-live-var-word-count vars)]
    [build : CompilerLiveFunctionGraphBuild
      (compiler-live-function-graph-build
        seq
        (compiler-live-build-block-array-nophi seq vars))]
    [graph0 : CompilerLiveBlockGraph (struct-get build graph)]
    [phi-out : (__tl_dyn-array CompilerLiveI64Set)
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
  [func : ir.CompilerIrFunction]) : CompilerFunctionLiveness
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
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
    [items : (__tl_dyn-array CompilerLiveI64Set) (struct-get sets items)]
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

(define (compiler-live-i64-ty) : ast.AstType
  (ast.AstType.I64))

(define (compiler-live-straight-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "straight")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 1)
            (compiler-live-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              1
              ir.CompilerIrBinOp.Add
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 2)
              (compiler-live-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
              ir.CompilerIrInstrList.Nil))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-live-branch-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "branch")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 0)
            (ir.compiler-ir-label "then")
            (ir.compiler-ir-label "else"))
          ir.CompilerIrInstrList.Nil))
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "then")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
            ir.CompilerIrInstrList.Nil))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "else")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
              ir.CompilerIrInstrList.Nil))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-live-phi-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "phi")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    4
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 0)
            (ir.compiler-ir-label "left")
            (ir.compiler-ir-label "right"))
          ir.CompilerIrInstrList.Nil))
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "left")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 10)
              (compiler-live-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "right")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 20)
                (compiler-live-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                ir.CompilerIrInstrList.Nil)))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "join")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Phi
                  3
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 1)
                    (ir.compiler-ir-label "left")
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 2)
                      (ir.compiler-ir-label "right")
                      ir.CompilerIrPhiInputList.Nil))
                  (compiler-live-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                  ir.CompilerIrInstrList.Nil)))
            ir.CompilerIrBlockList.Nil))))))

(define (compiler-live-use-def-ok?) : bool
  (let
    [use-def : CompilerLiveUseDef
      (compiler-live-block-use-def
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.Var 10)
            (compiler-live-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              1
              ir.CompilerIrBinOp.Add
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 11)
              (compiler-live-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.UnOp
                2
                ir.CompilerIrUnOp.Neg
                (ir.CompilerIrValue.Var 12)
                (compiler-live-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  3
                  (ir.compiler-ir-test-symbol "f")
                  (ir.CompilerIrCallArgs.Two
                    (ir.CompilerIrValue.Var 1)
                    (ir.CompilerIrValue.Var 13))
                  (compiler-live-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrValue.Var 14)
                    (compiler-live-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Var 15)
                      (ir.compiler-ir-label "a")
                      (ir.compiler-ir-label "b"))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Phi
                        4
                        (ir.compiler-ir-phi-input-cons
                          (ir.CompilerIrValue.Var 16)
                          (ir.compiler-ir-label "a")
                          ir.CompilerIrPhiInputList.Nil)
                        (compiler-live-i64-ty))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 4)))
                        ir.CompilerIrInstrList.Nil)))))))))]
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
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Alloc 0 (compiler-live-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.AddrOf 1 0)
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Gep
                2
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.Var 10)
                (compiler-live-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Load
                  3
                  (ir.CompilerIrValue.Var 2)
                  (compiler-live-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.StorePtr
                    (ir.CompilerIrValue.Var 2)
                    (ir.CompilerIrValue.Var 11)
                    (compiler-live-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Cast
                      4
                      (ir.CompilerIrValue.Var 3)
                      (compiler-live-i64-ty)
                      (ast.AstType.I32))
                    ir.CompilerIrInstrList.Nil)))))))]
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
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.LaneId 0 4 (compiler-live-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.Var 10)
              4
              (compiler-live-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.ir-instr-vector-bin-op
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1)
                4
                (compiler-live-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.TailMask
                  3
                  (ir.CompilerIrValue.Var 11)
                  (ir.CompilerIrValue.Var 12)
                  4)
                (ir.compiler-ir-instr-cons
                  (ir.ir-instr-predicated-load
                    4
                    (ir.CompilerIrValue.Var 13)
                    (ir.CompilerIrValue.Var 11)
                    (ir.CompilerIrValue.Var 3)
                    4
                    (compiler-live-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.ir-instr-predicated-store
                      (ir.CompilerIrValue.Var 14)
                      (ir.CompilerIrValue.Var 11)
                      (ir.CompilerIrValue.Var 2)
                      (ir.CompilerIrValue.Var 3)
                      4
                      (compiler-live-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.MaskReduce
                        5
                        (ir.CompilerIrMaskReduceOp.Any)
                        (ir.CompilerIrValue.Var 3)
                        4)
                      ir.CompilerIrInstrList.Nil))))))))]
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
      (ir.compiler-ir-label "entry"))
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
            (compiler-live-after liveness (ir.compiler-ir-label "entry") 0)
            (compiler-live-set2 0 2))
          (compiler-live-set-eq?
            (compiler-live-after liveness (ir.compiler-ir-label "entry") 1)
            (compiler-live-set1 1))
          (compiler-live-set-eq?
            (compiler-live-after liveness (ir.compiler-ir-label "entry") 2)
            (compiler-live-set-empty)))]
      [(CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : CompilerFunctionLiveness
      (compiler-live-analyze-function (compiler-live-branch-function))]
    (match (compiler-live-function-find-block
      liveness
      (ir.compiler-ir-label "entry"))
      [(CompilerLiveMaybeBlock.Some block)
        (and
          (=
            (compiler-live-label-set-count
              (compiler-live-block-successor-labels block))
            2)
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            (ir.compiler-ir-label "then"))
          (compiler-live-label-set-contains?
            (compiler-live-block-successor-labels block)
            (ir.compiler-ir-label "else"))
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
      (ir.compiler-ir-label "join"))
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
            (compiler-live-after liveness (ir.compiler-ir-label "join") 0)
            (compiler-live-set1 3))
          (match (compiler-live-function-find-block
            liveness
            (ir.compiler-ir-label "left"))
            [(CompilerLiveMaybeBlock.Some left-block)
              (compiler-live-label-set-contains?
                (compiler-live-block-successor-labels left-block)
                (ir.compiler-ir-label "join"))]
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
      (ir.compiler-ir-label "join"))
      [(CompilerLiveMaybeBlock.Some baseline-join)
        (match (compiler-live-function-find-block
          edge-precise
          (ir.compiler-ir-label "join"))
          [(CompilerLiveMaybeBlock.Some edge-precise-join)
            (match (compiler-live-function-find-block
              baseline
              (ir.compiler-ir-label "left"))
              [(CompilerLiveMaybeBlock.Some baseline-left)
                (match (compiler-live-function-find-block
                  edge-precise
                  (ir.compiler-ir-label "left"))
                  [(CompilerLiveMaybeBlock.Some edge-precise-left)
                    (match (compiler-live-function-find-block
                      edge-precise
                      (ir.compiler-ir-label "right"))
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
    [cases : ir.CompilerIrSwitchCaseList
      (ir.compiler-ir-switch-case-cons
        4
        (ir.compiler-ir-label "four")
        (ir.compiler-ir-switch-case-cons
          5
          (ir.compiler-ir-label "five")
          ir.CompilerIrSwitchCaseList.Nil))]
    [instr : ir.CompilerIrInstr
      (ir.CompilerIrInstr.Switch
        (ir.CompilerIrValue.Var 9)
        4
        cases
        (ir.compiler-ir-label "other"))]
    [instrs : ir.CompilerIrInstrList
      (ir.compiler-ir-instr-cons instr ir.CompilerIrInstrList.Nil)]
    [block : ir.CompilerIrBlock
      (ir.compiler-ir-block (ir.compiler-ir-label "entry") instrs)]
    [successors : CompilerLiveLabelSet (compiler-live-block-successors block)]
    [use-def : CompilerLiveUseDef (compiler-live-block-use-def instrs)]
    (and
      (compiler-live-set-eq? (struct-get use-def uses) (compiler-live-set1 9))
      (compiler-live-set-eq?
        (struct-get use-def defs)
        (compiler-live-set-empty))
      (= (compiler-live-label-set-count successors) 3)
      (compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "four"))
      (compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "five"))
      (compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "other")))))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-set-ops-ok?)
    (compiler-live-scratch-ops-ok?)
    (compiler-live-step-ids-ok?)
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
(define (compiler-live-ir-block-list-to-seq [blocks : ir.CompilerIrBlockList]) : ir.CompilerIrBlockSeq
  (match blocks
    [(ir.CompilerIrBlockList.Array seq) seq]
    [_ (ir.compiler-ir-block-seq-from-list blocks)]))

(define (compiler-live-build-block-array-with
  [blocks : ir.CompilerIrBlockSeq]
  [vars : i64]
  [edge-precise? : bool]) : (__tl_dyn-array CompilerLiveBlock)
  (let
    [count : i64 (ir.compiler-ir-block-seq-count blocks)]
    [out : (__tl_dyn-array CompilerLiveBlock)
      (make-array CompilerLiveBlock count)]
    [word-count : i64 (compiler-live-var-word-count vars)]
    [uses : (__tl_dyn-array i64) (make-array i64 word-count)]
    [defs : (__tl_dyn-array i64) (make-array i64 word-count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (let
          [block : ir.CompilerIrBlock (ir.compiler-ir-block-seq-ref blocks i)]
          (begin
            (match block
              [(ir.CompilerIrBlock.Block _ instrs)
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
  [blocks : ir.CompilerIrBlockSeq]
  [vars : i64]) : (__tl_dyn-array CompilerLiveBlock)
  (compiler-live-build-block-array-with blocks vars false))

(define (compiler-live-build-block-array-nophi
  [blocks : ir.CompilerIrBlockSeq]
  [vars : i64]) : (__tl_dyn-array CompilerLiveBlock)
  (compiler-live-build-block-array-with blocks vars true))

(define (compiler-live-phi-out-build-seq!
  [blocks : ir.CompilerIrBlockSeq]
  [ids : (& ids live_label_map.Map)]
  [phi-out : (__tl_dyn-array CompilerLiveI64Set)]) : unit
  (let
    [count : i64 (ir.compiler-ir-block-seq-count blocks)]
    [i : i64 0]
    (while (< i count)
      (begin
        (match (ir.compiler-ir-block-seq-ref blocks i)
          [(ir.CompilerIrBlock.Block _ instrs)
            (compiler-live-phi-out-add-seq! instrs ids phi-out)])
        (set! i (+ i 1))))))

(define (compiler-live-block-graph-fill-successors-from-array!
  [blocks : (__tl_dyn-array CompilerLiveBlock)]
  [ids : (& ids live_label_map.Map)]
  [successors : (__tl_dyn-array CompilerLiveIndexVec)]
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
  [blocks : (__tl_dyn-array CompilerLiveBlock)]) : CompilerLiveBlockGraph
  (let
    [count : i64 (array-length blocks)]
    [successors : (__tl_dyn-array CompilerLiveIndexVec)
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
  [seq : ir.CompilerIrBlockSeq]
  [live-blocks : (__tl_dyn-array CompilerLiveBlock)]) : CompilerLiveFunctionGraphBuild
  (let
    [graph : CompilerLiveBlockGraph
      (compiler-live-block-graph-build-from-array live-blocks)]
    (CompilerLiveFunctionGraphBuild seq graph)))

(define (compiler-live-fill-instr-after-graph-seq!
  [ir-blocks : ir.CompilerIrBlockSeq]
  [blocks : (__tl_dyn-array CompilerLiveBlock)]
  [word-count : i64]
  [edge-precise? : bool]) : unit
  (let
    [count : i64
      (compiler-live-set-min
        (ir.compiler-ir-block-seq-count ir-blocks)
        (array-length blocks))]
    [words : (__tl_dyn-array i64) (make-array i64 word-count)]
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set!
          blocks
          i
          (compiler-live-fill-instr-after-block
            (ir.compiler-ir-block-seq-ref ir-blocks i)
            (array-ref blocks i)
            words
            edge-precise?))
        (set! i (+ i 1))))))

(define (compiler-live-fixpoint
  [graph : CompilerLiveBlockGraph]
  [word-count : i64]) : CompilerLiveBlockGraph
  (let
    [blocks : (__tl_dyn-array CompilerLiveBlock) (struct-get graph blocks)]
    [pending : (__tl_dyn-array bool)
      (make-array bool (array-length (struct-get graph blocks)))]
    [words : (__tl_dyn-array i64) (make-array i64 word-count)]
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