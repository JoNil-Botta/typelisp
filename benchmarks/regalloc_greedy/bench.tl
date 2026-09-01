;# benchmarks/regalloc_greedy/bench.tl - the RAGreedy selectOrSplit pass.
;#
;# Equivalent to benchmarks/regalloc_greedy/baseline.c. The kernel is the
;# TypeLisp compiler's own LLVM-style per-vreg Greedy register allocator, run
;# over real live intervals, spill weights, copy hints and clobber points that
;# the compiler produced while compiling itself (see README.md for the corpus
;# and its regeneration command).
;#
;# Mirrored compiler functions, all in src/compiler_regalloc.tl:
;#   compiler-reg-greedy-combine-spill-weights / -combine-tie-span
;#   compiler-reg-priority-keys! / -priority-band-value /
;#     -block-index-of-point / -priority-key-weight
;#   compiler-reg-greedy-weight-before? / -merge-run! / -merge-pass! /
;#     -copy-range! / -sort!            (the stable bottom-up merge sort)
;#   compiler-reg-greedy-heap-weight / -heap-better? / -heap-swap! /
;#     -heap-sift-up! / -heap-sift-down! / -heap-push! / -heap-pop!
;#   compiler-reg-greedy-worklist-seed! / -worklist-run! / -alloc-all!
;#   compiler-reg-greedy-alloc-one!     (the whole RS_* stage machine)
;#   compiler-reg-greedy-already-assigned? / -var-spans-clobber? /
;#     -forbidden-regs / -arg-pref-reg / -hint-free-reg / -first-free /
;#     -reg-free? / -interferer-max / -interferer-max-capped /
;#     -first-evictable / -evict-requeue! / -evict-cascade-cap / -evict-inf
;#   compiler-reg-greedy-occupancy-make / -word-index / -set-bit! / -clear! /
;#     -assign! / -pool-index-build / -pool-index
;#   compiler-reg-live-union-empty / -entry-words / -neg-inf /
;#     -effective-start / -lower-bound / -segment-hits? / -interferes? /
;#     -refresh-max! / -insert-segment! / -add! / -remove!
;#   compiler-reg-greedy-assignment-register! / -spill! / -unassign! and
;#     compiler-reg-assignment-table-insert / -unassign / -lookup
;#   compiler-reg-interval-overlap? / -interval-seq-overlaps? /
;#     compiler-reg-vars-interfere-segmented-index? / -vars-interfere-index?
;#   compiler-reg-call-set-in-range? / -call-word-in-range? /
;#     compiler-reg-segments-span-clobber?
;#   compiler-reg-low-bit-index32 / -low-bit-index32-nonzero (De Bruijn)
;#   compiler-reg-greedy-integer-pool-for-abi Linux / -caller-saved-count
;#   compiler-reg-assignment-table-location-conflicts? (the self-check)
;#
;# KEPT. The whole single allocation algorithm: the spill-weight priority
;# worklist (binary max-heap over weight desc / var asc with the pending array
;# authoritative and lazy discard on pop), the per-physreg LiveIntervalUnion
;# (three i64 per entry -- effective start, end, prefix maximum of end -- sorted
;# by effective start and queried with one binary search per candidate
;# segment), the per-resident bitset scan with the sound segmented interference
;# predicate as its fallback and as the eviction scan, call/div/shift clobber as
;# interference, the ABI arg-register preference, the copy hint, first-free,
;# eviction with requeue under the cascade cap, and the RS_New/Assign/Split/
;# Spill stages. The integer pool is the SysV pool
;# `compiler-reg-greedy-integer-pool-for-abi Linux` in order, with the same
;# caller-saved prefix of 9.
;#
;# DROPPED, and why the kept part is what costs: (1) the region-split post-pass
;# -- RS_Split roots are counted as such, exactly the decision alloc-one! makes,
;# and the splitter is a separate IR-rewriting pass; (2) group/pair roots and
;# scratch pseudos -- the compiler leaves them unassigned, so the group set is
;# empty here and `unspillable-from` is -1, the values both take on every
;# ordinary function; (3) the AVX/XMM classes -- a second run of this same
;# function over a different pool; (4) the call-spanning save/restore rescue and
;# the coalescer -- both run outside selectOrSplit, and the corpus carries the
;# per-var intervals the allocator sees; (5) the remat discount, so the
;# combine's discounted input is its raw input (the exporter has no
;# rematerialisability judgement); (6) pre-seeded ABI pins -- every function
;# starts from an empty assignment table, which only removes residents from the
;# union at t=0.
;#
;# SELF-CHECK. After every function the plan is verified conflict-free the way
;# `compiler-reg-assignment-table-location-conflicts?` does -- no two vars
;# holding the same register may have overlapping segments -- and the number of
;# vars whose interval spans a call point is recomputed and compared against the
;# total the exporter derived independently in Python (corpus line 3).
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division, so the printed decimal matches the C baseline's
;# `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (rg-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (rg-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (rg-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (rg-ref [items : Expr] [index : Expr]) : Expr
  `(rg-vec-ref (& ,items) ,index))

(defmacro (rg-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(rg-vec-set! (&mut ,items) ,index ,value))

(define rg-hash-basis : i64
  1469598103934665603)
(define rg-hash-prime : i64
  1099511628211)

;; compiler-reg-greedy-integer-pool-for-abi Linux: the caller-saved zero-call
;; scratch first, then the rest of the caller-saved pool, then the five
;; callee-saved registers. compiler-reg-greedy-caller-saved-count = 14 - 5.
(define rg-pool-count : i64
  14)
(define rg-caller-saved-count : i64
  9)

;; cabi.compiler-reg-id-*: rax=0 rcx=1 rdx=2 rbx=3 rsi=6 rdi=7 r8..r15=8..15.
(define rg-id-rax : i64
  0)
(define rg-id-rcx : i64
  1)
(define rg-id-rdx : i64
  2)

;; compiler-reg-greedy-pool-index-capacity: mask base 96 + mask count 8.
(define rg-pool-index-capacity : i64
  104)
(define rg-word-bits : i64
  32)

;; compiler-reg-priority-band-span / -priority-local-span.
(define rg-band-span : i64
  2097152)
(define rg-local-span : i64
  1048576)

;; compiler-reg-greedy-combine-tie-span / compiler-reg-spill-weight-cap.
(define rg-tie-span : i64
  1024)
(define rg-weight-cap : i64
  1073741824)

;; compiler-reg-greedy-evict-cascade-cap / -evict-inf.
(define rg-evict-cap : i64
  4)
(define rg-evict-inf : i64
  35184372088832)

;; compiler-reg-live-union-neg-inf / -entry-words.
(define rg-neg-inf : i64
  -1000000000)
(define rg-entry-words : i64
  3)

;; compiler-reg-greedy-stage-rs-new / -assign / -split / -spill.
(define rg-stage-new : i64
  0)
(define rg-stage-assign : i64
  1)
(define rg-stage-split : i64
  2)
(define rg-stage-spill : i64
  3)

;; Parsed corpus tokens and the scratch arrays every per-function pass reuses.
;; Module globals keep the allocator functions parameterless, matching how the
;; compiler threads one workspace through a pass.
(define rg-tokens : i64vec.Vec
  (rg-zero-vec 1))
(define rg-offsets : i64vec.Vec
  (rg-zero-vec 1))
(define rg-lowbit : i64vec.Vec
  (rg-zero-vec 1))
(define rg-pool-reg : i64vec.Vec
  (rg-zero-vec 1))
(define rg-pool-idx : i64vec.Vec
  (rg-zero-vec 1))
(define rg-seg-lo : i64vec.Vec
  (rg-zero-vec 1))
(define rg-seg-hi : i64vec.Vec
  (rg-zero-vec 1))
(define rg-seg-start : i64vec.Vec
  (rg-zero-vec 1))
(define rg-seg-end : i64vec.Vec
  (rg-zero-vec 1))
(define rg-raw : i64vec.Vec
  (rg-zero-vec 1))
(define rg-key : i64vec.Vec
  (rg-zero-vec 1))
(define rg-hint : i64vec.Vec
  (rg-zero-vec 1))
(define rg-argpref : i64vec.Vec
  (rg-zero-vec 1))
(define rg-param : i64vec.Vec
  (rg-zero-vec 1))
(define rg-group : i64vec.Vec
  (rg-zero-vec 1))
(define rg-present : i64vec.Vec
  (rg-zero-vec 1))
(define rg-kind : i64vec.Vec
  (rg-zero-vec 1))
(define rg-reg : i64vec.Vec
  (rg-zero-vec 1))
(define rg-primary : i64vec.Vec
  (rg-zero-vec 1))
(define rg-secondary : i64vec.Vec
  (rg-zero-vec 1))
(define rg-pending : i64vec.Vec
  (rg-zero-vec 1))
(define rg-evict : i64vec.Vec
  (rg-zero-vec 1))
(define rg-stage : i64vec.Vec
  (rg-zero-vec 1))
(define rg-order : i64vec.Vec
  (rg-zero-vec 1))
(define rg-sortbuf : i64vec.Vec
  (rg-zero-vec 1))
(define rg-heap : i64vec.Vec
  (rg-zero-vec 1))
(define rg-occ : i64vec.Vec
  (rg-zero-vec 1))
(define rg-union : i64vec.Vec
  (rg-zero-vec 1))
(define rg-ucount : i64vec.Vec
  (rg-zero-vec 1))
(define rg-ucoarse : i64vec.Vec
  (rg-zero-vec 1))
(define rg-callbits : i64vec.Vec
  (rg-zero-vec 1))
(define rg-divbits : i64vec.Vec
  (rg-zero-vec 1))
(define rg-shiftbits : i64vec.Vec
  (rg-zero-vec 1))
(define rg-forb : i64vec.Vec
  (rg-zero-vec 1))
(define rg-residents : i64vec.Vec
  (rg-zero-vec 1))

;; Per-function view of the corpus, set by rg-load-function before it runs.
(define rg-vars : i64
  0)
(define rg-nblocks : i64
  0)
(define rg-ncand : i64
  0)
(define rg-nrows : i64
  0)
(define rg-points-base : i64
  0)
(define rg-cand-base : i64
  0)
(define rg-wordcount : i64
  1)
(define rg-clobber-words : i64
  1)
(define rg-ustride : i64
  3)
(define rg-heap-len : i64
  0)
(define rg-forb-count : i64
  0)
(define rg-hint-start : i64
  0)
(define rg-assigned : i64
  0)
(define rg-spilled : i64
  0)
(define rg-splits : i64
  0)
(define rg-evictions : i64
  0)
(define rg-spans-seen : i64
  0)

;; 1 only on the first round: the conflict verification is a per-function
;; property, so checking each function once per run is what the self-check
;; needs, and the later rounds measure the allocator alone.
(define rg-verify : i64
  0)

(define (rg-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) rg-hash-prime))

(define (rg-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (rg-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (rg-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (rg-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (rg-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (rg-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (rg-digit? (rg-byte-at text n i))
                    (begin
                      (set! value (+ (* value 10) (- (rg-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; compiler-reg-low-bit-index32 / -low-bit-index32-nonzero: the De Bruijn
;; multiply-and-look-up index of the lowest set bit of a 32-bit word. The
;; nonzero form drops the guard, exactly as the compiler's bit walks do.
(defmacro (rg-low-bit-nz [bits : Expr]) : Expr
  `(let
    [value : i64 ,bits]
    [isolated : i64 (bit-and value (- 0 value))]
    [slot : i64 (shr (bit-and (* isolated 125613361) 4294967295) 27)]
    (rg-ref rg-lowbit slot)))

(define (rg-lowbit-init!) : unit
  (begin
    (rg-set! rg-lowbit 0 0)
    (rg-set! rg-lowbit 1 1)
    (rg-set! rg-lowbit 2 28)
    (rg-set! rg-lowbit 3 2)
    (rg-set! rg-lowbit 4 29)
    (rg-set! rg-lowbit 5 14)
    (rg-set! rg-lowbit 6 24)
    (rg-set! rg-lowbit 7 3)
    (rg-set! rg-lowbit 8 30)
    (rg-set! rg-lowbit 9 22)
    (rg-set! rg-lowbit 10 20)
    (rg-set! rg-lowbit 11 15)
    (rg-set! rg-lowbit 12 25)
    (rg-set! rg-lowbit 13 17)
    (rg-set! rg-lowbit 14 4)
    (rg-set! rg-lowbit 15 8)
    (rg-set! rg-lowbit 16 31)
    (rg-set! rg-lowbit 17 27)
    (rg-set! rg-lowbit 18 13)
    (rg-set! rg-lowbit 19 23)
    (rg-set! rg-lowbit 20 21)
    (rg-set! rg-lowbit 21 19)
    (rg-set! rg-lowbit 22 16)
    (rg-set! rg-lowbit 23 7)
    (rg-set! rg-lowbit 24 26)
    (rg-set! rg-lowbit 25 12)
    (rg-set! rg-lowbit 26 18)
    (rg-set! rg-lowbit 27 6)
    (rg-set! rg-lowbit 28 11)
    (rg-set! rg-lowbit 29 5)
    (rg-set! rg-lowbit 30 10)
    (rg-set! rg-lowbit 31 9)))

;; compiler-reg-greedy-pool-index-build / -pool-index: canonical register id ->
;; pool slot, first occurrence wins, -1 when the register is not in the pool.
(define (rg-pool-init!) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i rg-pool-index-capacity)
        (begin
          (rg-set! rg-pool-idx i -1)
          (set! i (+ i 1))))
      (rg-set! rg-pool-reg 0 rg-id-rax)
      (rg-set! rg-pool-reg 1 6)
      (rg-set! rg-pool-reg 2 7)
      (rg-set! rg-pool-reg 3 9)
      (rg-set! rg-pool-reg 4 rg-id-rcx)
      (rg-set! rg-pool-reg 5 rg-id-rdx)
      (rg-set! rg-pool-reg 6 10)
      (rg-set! rg-pool-reg 7 11)
      (rg-set! rg-pool-reg 8 8)
      (rg-set! rg-pool-reg 9 12)
      (rg-set! rg-pool-reg 10 13)
      (rg-set! rg-pool-reg 11 14)
      (rg-set! rg-pool-reg 12 15)
      (rg-set! rg-pool-reg 13 3)
      (set! i 0)
      (while (< i rg-pool-count)
        (let
          [key : i64 (rg-ref rg-pool-reg i)]
          (begin
            (when
              (and
                (>= key 0)
                (< key rg-pool-index-capacity)
                (< (rg-ref rg-pool-idx key) 0))
              (rg-set! rg-pool-idx key i))
            (set! i (+ i 1))))))))

(define (rg-pool-index [reg : i64]) : i64
  (if (and (>= reg 0) (< reg rg-pool-index-capacity))
    (rg-ref rg-pool-idx reg)
    -1))

;; compiler-reg-id-seq-contains? over the per-root forbidden register set.
(define (rg-forbidden? [reg : i64]) : bool
  (let
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i rg-forb-count) (not found))
        (begin
          (when (= (rg-ref rg-forb i) reg) (set! found true))
          (set! i (+ i 1))))
      found)))

;; compiler-reg-id-seq-contains? over `hint-regs`: the whole pool, or -- for a
;; call-spanning or parameter root -- only the callee-saved suffix.
(define (rg-hint-allowed? [reg : i64]) : bool
  (let
    [i : i64 rg-hint-start]
    [found : bool false]
    (begin
      (while (and (< i rg-pool-count) (not found))
        (begin
          (when (= (rg-ref rg-pool-reg i) reg) (set! found true))
          (set! i (+ i 1))))
      found)))

;; compiler-reg-call-word-in-range?: does this clobber word hold a point
;; strictly inside (start, end)?
(define (rg-call-word-in-range?
  [bits : i64]
  [base : i64]
  [start : i64]
  [end : i64]) : bool
  (if (= bits 0)
    false
    (let
      [c : i64 (+ base (rg-low-bit-nz bits))]
      (if (and (< start c) (< c end))
        true
        (rg-call-word-in-range? (bit-and bits (- bits 1)) base start end)))))

(define (rg-call-set-in-range-words?
  [set : (& set i64vec.Vec)]
  [start : i64]
  [end : i64]
  [word-index : i64]
  [last-word : i64]) : bool
  (if (> word-index last-word)
    false
    (if (rg-call-word-in-range?
      (rg-vec-ref set word-index)
      (* word-index rg-word-bits)
      start
      end)
      true
      (rg-call-set-in-range-words? set start end (+ word-index 1) last-word))))

;; compiler-reg-call-set-in-range?: only the words holding positions inside
;; (start, end) can answer yes, so the scan starts and stops at those words.
(define (rg-call-set-in-range?
  [set : (& set i64vec.Vec)]
  [start : i64]
  [end : i64]) : bool
  (let
    [last-pos : i64 (- end 1)]
    [first-pos : i64
      (if (< (+ start 1) 0)
        0
        (+ start 1))]
    (if (> first-pos last-pos)
      false
      (let
        [first-word : i64 (shr first-pos 5)]
        [raw-last-word : i64 (shr last-pos 5)]
        [last-word : i64
          (if (>= raw-last-word rg-clobber-words)
            (- rg-clobber-words 1)
            raw-last-word)]
        (if (> first-word last-word)
          false
          (rg-call-set-in-range-words? set start end first-word last-word))))))

;; compiler-reg-segments-span-clobber?: a clobber at the hull start is that
;; value's own definition, so only that segment keeps the exclusive start.
(define (rg-segments-span-clobber?
  [var : i64]
  [set : (& set i64vec.Vec)]
  [hull-start : i64]) : bool
  (let
    [index : i64 (rg-ref rg-seg-lo var)]
    [limit : i64 (rg-ref rg-seg-hi var)]
    [hit : bool false]
    (begin
      (while (and (< index limit) (not hit))
        (let
          [segment-start : i64 (rg-ref rg-seg-start index)]
          [low : i64
            (if (= segment-start hull-start)
              segment-start
              (- segment-start 1))]
          (begin
            (when
              (rg-call-set-in-range? set low (rg-ref rg-seg-end index))
              (set! hit true))
            (set! index (+ index 1)))))
      hit)))

;; compiler-reg-greedy-var-spans-clobber?: the coarse hull gate, then the
;; segment-aware answer (a hull hole is genuine deadness).
(define (rg-var-spans-clobber? [var : i64] [set : (& set i64vec.Vec)]) : bool
  (let
    [lo : i64 (rg-ref rg-seg-lo var)]
    [hi : i64 (rg-ref rg-seg-hi var)]
    (if (= lo hi)
      true
      (let
        [hull-start : i64 (rg-ref rg-seg-start lo)]
        [hull-end : i64 (rg-ref rg-seg-end (- hi 1))]
        (and
          (rg-call-set-in-range? set hull-start hull-end)
          (rg-segments-span-clobber? var set hull-start))))))

;; compiler-reg-interval-seq-overlaps?, over compiler-reg-interval-overlap?'s
;; boundary rule: half-open, except that a touch at point 0 counts as overlap
;; (a parameter's home was written in the prologue). Both inputs ascend by
;; start, so the scan retires whichever segment ends first and neither cursor
;; retreats.
(define (rg-seq-overlaps?
  [left-lo : i64]
  [left-hi : i64]
  [right-lo : i64]
  [right-hi : i64]) : bool
  (let
    [left-index : i64 left-lo]
    [right-index : i64 right-lo]
    [overlap : bool false]
    (begin
      (while (and (< left-index left-hi) (< right-index right-hi) (not overlap))
        (let
          [left-start : i64 (rg-ref rg-seg-start left-index)]
          [left-end : i64 (rg-ref rg-seg-end left-index)]
          [right-start : i64 (rg-ref rg-seg-start right-index)]
          [right-end : i64 (rg-ref rg-seg-end right-index)]
          (cond
            [(and (<= left-end right-start) (not (= right-start 0)))
              (set! left-index (+ left-index 1))]
            [(and (<= right-end left-start) (not (= left-start 0)))
              (set! right-index (+ right-index 1))]
            [else (set! overlap true)])))
      overlap)))

;; compiler-reg-vars-interfere-segmented-index?: per-var segments when both
;; sides have them, the coarse hull as the conservative fallback.
(define (rg-vars-interfere? [left : i64] [right : i64]) : bool
  (if (= left right)
    true
    (let
      [left-lo : i64 (rg-ref rg-seg-lo left)]
      [left-hi : i64 (rg-ref rg-seg-hi left)]
      [right-lo : i64 (rg-ref rg-seg-lo right)]
      [right-hi : i64 (rg-ref rg-seg-hi right)]
      ;; compiler-reg-vars-interfere-index? is the fallback, and a var with no
      ;; segments has no coarse interval either, so it answers `true`.
      (if (and (not (= left-lo left-hi)) (not (= right-lo right-hi)))
        (rg-seq-overlaps? left-lo left-hi right-lo right-hi)
        true))))

;; compiler-reg-live-union-effective-start: a start of 0 maps below every real
;; program point, which collapses the point-0 disjunction into one comparison.
(define (rg-effective-start [start : i64]) : i64
  (if (= start 0)
    rg-neg-inf
    start))

;; compiler-reg-live-union-lower-bound.
(define (rg-union-lower-bound [reg-index : i64] [count : i64] [bound : i64]) : i64
  (let
    [base : i64 (* reg-index rg-ustride)]
    [lo : i64 0]
    [hi : i64 count]
    (begin
      (while (< lo hi)
        (let
          [mid : i64 (+ lo (shr (- hi lo) 1))]
          (if (< (rg-ref rg-union (+ base (* mid rg-entry-words))) bound)
            (set! lo (+ mid 1))
            (set! hi mid))))
      lo)))

;; compiler-reg-live-union-segment-hits?: one binary search plus one load.
(define (rg-union-segment-hits?
  [reg-index : i64]
  [count : i64]
  [es-start : i64]
  [end : i64]) : bool
  (let
    [above : i64 (rg-union-lower-bound reg-index count end)]
    (if (= above 0)
      false
      (>
        (rg-ref
          rg-union
          (+ (* reg-index rg-ustride) (+ (* (- above 1) rg-entry-words) 2)))
        es-start))))

;; compiler-reg-live-union-interferes?
(define (rg-union-interferes? [reg-index : i64] [lo : i64] [hi : i64]) : bool
  (let
    [count : i64 (rg-ref rg-ucount reg-index)]
    [index : i64 lo]
    [hit : bool false]
    (begin
      (while (and (< index hi) (not hit))
        (begin
          (when
            (rg-union-segment-hits?
              reg-index
              count
              (rg-effective-start (rg-ref rg-seg-start index))
              (rg-ref rg-seg-end index))
            (set! hit true))
          (set! index (+ index 1))))
      hit)))

;; compiler-reg-live-union-refresh-max!: prefix maxima of `end` over [from, n).
(define (rg-union-refresh-max! [reg-index : i64] [count : i64] [from : i64]) : unit
  (let
    [base : i64 (* reg-index rg-ustride)]
    [index : i64
      (if (< from 0)
        0
        from)]
    [running : i64
      (if (> index 0)
        (rg-ref rg-union (+ base (+ (* (- index 1) rg-entry-words) 2)))
        rg-neg-inf)]
    (while (< index count)
      (let
        [at : i64 (+ base (* index rg-entry-words))]
        [end : i64 (rg-ref rg-union (+ at 1))]
        (begin
          (when (> end running) (set! running end))
          (rg-set! rg-union (+ at 2) running)
          (set! index (+ index 1)))))))

;; compiler-reg-live-union-insert-segment!: keep the entries sorted by
;; effective start; ties keep insertion order.
(define (rg-union-insert-segment!
  [reg-index : i64]
  [es-start : i64]
  [end : i64]) : unit
  (let
    [base : i64 (* reg-index rg-ustride)]
    [count : i64 (rg-ref rg-ucount reg-index)]
    [at : i64 (rg-union-lower-bound reg-index count es-start)]
    [cursor : i64 (- (* count rg-entry-words) 1)]
    [floor : i64 (* at rg-entry-words)]
    (begin
      (while (>= cursor floor)
        (begin
          (rg-set!
            rg-union
            (+ base (+ cursor rg-entry-words))
            (rg-ref rg-union (+ base cursor)))
          (set! cursor (- cursor 1))))
      (rg-set! rg-union (+ base floor) es-start)
      (rg-set! rg-union (+ base (+ floor 1)) end)
      (rg-set! rg-ucount reg-index (+ count 1))
      (rg-union-refresh-max! reg-index (+ count 1) at))))

;; compiler-reg-live-union-add!: a var without segment data cannot be modelled
;; by the union and only bumps the coarse-resident count.
(define (rg-union-add! [reg-index : i64] [var : i64]) : unit
  (let
    [lo : i64 (rg-ref rg-seg-lo var)]
    [hi : i64 (rg-ref rg-seg-hi var)]
    [index : i64 lo]
    (if (= lo hi)
      (rg-set! rg-ucoarse reg-index (+ (rg-ref rg-ucoarse reg-index) 1))
      (while (< index hi)
        (begin
          (rg-union-insert-segment!
            reg-index
            (rg-effective-start (rg-ref rg-seg-start index))
            (rg-ref rg-seg-end index))
          (set! index (+ index 1)))))))

;; compiler-reg-live-union-remove!: both sides ascend in effective start, so
;; one merge pass compacts out exactly one entry per segment.
(define (rg-union-remove! [reg-index : i64] [var : i64]) : unit
  (let
    [lo : i64 (rg-ref rg-seg-lo var)]
    [hi : i64 (rg-ref rg-seg-hi var)]
    (if (= lo hi)
      (rg-set! rg-ucoarse reg-index (- (rg-ref rg-ucoarse reg-index) 1))
      (let
        [base : i64 (* reg-index rg-ustride)]
        [count : i64 (rg-ref rg-ucount reg-index)]
        [read : i64 0]
        [write : i64 0]
        [seg-index : i64 lo]
        [first-drop : i64 count]
        (begin
          (while (< read count)
            (let
              [from : i64 (+ base (* read rg-entry-words))]
              [to : i64 (+ base (* write rg-entry-words))]
              [matched : bool
                (if (< seg-index hi)
                  (and
                    (=
                      (rg-ref rg-union from)
                      (rg-effective-start (rg-ref rg-seg-start seg-index)))
                    (=
                      (rg-ref rg-union (+ from 1))
                      (rg-ref rg-seg-end seg-index)))
                  false)]
              (begin
                (if matched
                  (begin
                    (when (< write first-drop) (set! first-drop write))
                    (set! seg-index (+ seg-index 1)))
                  (begin
                    (when
                      (not (= from to))
                      (begin
                        (rg-set! rg-union to (rg-ref rg-union from))
                        (rg-set! rg-union (+ to 1) (rg-ref rg-union (+ from 1)))))
                    (set! write (+ write 1))))
                (set! read (+ read 1)))))
          (rg-set! rg-ucount reg-index write)
          (rg-union-refresh-max! reg-index write first-drop))))))

;; compiler-reg-greedy-occupancy-set-bit!: the union mirrors the bitset
;; exactly, so it is only touched when this call actually flips the bit.
(define (rg-occupancy-set-bit! [reg-index : i64] [var : i64] [present : bool]) : unit
  (if (or (< reg-index 0) (< var 0) (>= var rg-vars))
    unit
    (let
      [word-index : i64 (shr var 5)]
      (if (>= word-index rg-wordcount)
        unit
        (let
          [flat-index : i64 (+ (* reg-index rg-wordcount) word-index)]
          [mask : i64 (shl 1 (bit-and var 31))]
          [old : i64 (rg-ref rg-occ flat-index)]
          [was-set : bool (not (= (bit-and old mask) 0))]
          (begin
            (if present
              (when (not was-set) (rg-union-add! reg-index var))
              (when was-set (rg-union-remove! reg-index var)))
            (rg-set!
              rg-occ
              flat-index
              (if present
                (bit-or old mask)
                (bit-and old (bit-xor mask -1))))))))))

;; compiler-reg-greedy-occupancy-clear!
(define (rg-occupancy-clear! [var : i64]) : unit
  (if (or (< var 0) (>= var rg-vars))
    unit
    (let
      [first : i64 (rg-ref rg-primary var)]
      [second : i64 (rg-ref rg-secondary var)]
      (begin
        (rg-occupancy-set-bit! first var false)
        (when
          (and (>= second 0) (not (= first second)))
          (rg-occupancy-set-bit! second var false))
        (rg-set! rg-primary var -1)
        (rg-set! rg-secondary var -1)))))

;; compiler-reg-greedy-occupancy-assign!
(define (rg-occupancy-assign! [var : i64] [first : i64] [second : i64]) : unit
  (if (or (< var 0) (>= var rg-vars))
    unit
    (begin
      (rg-occupancy-clear! var)
      (rg-set! rg-primary var first)
      (rg-set! rg-secondary var second)
      (rg-occupancy-set-bit! first var true)
      (when
        (and (>= second 0) (not (= first second)))
        (rg-occupancy-set-bit! second var true)))))

;; compiler-reg-greedy-assignment-register! / -spill! / -unassign! over
;; compiler-reg-assignment-table-insert / -unassign.
(define (rg-assign-register! [var : i64] [reg-index : i64]) : unit
  (begin
    (rg-occupancy-assign! var reg-index -1)
    (rg-set! rg-present var 1)
    (rg-set! rg-kind var 1)
    (rg-set! rg-reg var (rg-ref rg-pool-reg reg-index))))

(define (rg-assign-spill! [var : i64]) : unit
  (begin
    (rg-occupancy-clear! var)
    (rg-set! rg-present var 1)
    (rg-set! rg-kind var 2)
    (rg-set! rg-reg var -1)))

(define (rg-assign-unassign! [var : i64]) : unit
  (begin
    (rg-occupancy-clear! var)
    (rg-set! rg-present var 0)
    (rg-set! rg-kind var 0)
    (rg-set! rg-reg var -1)))

;; compiler-reg-priority-key-weight: the band-free spill weight of a key.
(define (rg-key-weight [key : i64]) : i64
  (if (< key 0)
    key
    (/ key rg-band-span)))

;; compiler-reg-greedy-interferer-max: max weight among vars holding
;; `reg-index` that interfere with `var`; -1 if none.
(define (rg-interferer-max
  [var : i64]
  [reg-index : i64]
  [word-index : i64]
  [acc : i64]) : i64
  (if (>= word-index rg-wordcount)
    acc
    (let
      [bits : i64 (rg-ref rg-occ (+ (* reg-index rg-wordcount) word-index))]
      [best : i64 acc]
      (begin
        (while (not (= bits 0))
          (let
            [other : i64 (+ (* word-index rg-word-bits) (rg-low-bit-nz bits))]
            (begin
              (when
                (and (not (= other var)) (rg-vars-interfere? var other))
                (let
                  [weight : i64
                    (if (< other rg-vars)
                      (rg-ref rg-key other)
                      0)]
                  (when (> weight best) (set! best weight))))
              (set! bits (bit-and bits (- bits 1))))))
        (rg-interferer-max var reg-index (+ word-index 1) best)))))

;; compiler-reg-greedy-reg-free?: the union answers when the candidate has
;; segments, no resident of this register lacks them, and the candidate is not
;; itself a resident; otherwise the per-resident scan is the backstop.
(define (rg-reg-free? [var : i64] [reg-index : i64]) : bool
  (let
    [lo : i64 (rg-ref rg-seg-lo var)]
    [hi : i64 (rg-ref rg-seg-hi var)]
    (if (and
      (not (= lo hi))
      (= (rg-ref rg-ucoarse reg-index) 0)
      (not (= (rg-ref rg-primary var) reg-index))
      (not (= (rg-ref rg-secondary var) reg-index)))
      (not (rg-union-interferes? reg-index lo hi))
      (= (rg-interferer-max var reg-index 0 -1) -1))))

;; compiler-reg-greedy-first-free
(define (rg-first-free [var : i64] [ridx : i64] [rcount : i64]) : i64
  (if (>= ridx rcount)
    -1
    (if (and
      (not (rg-forbidden? (rg-ref rg-pool-reg ridx)))
      (rg-reg-free? var ridx))
      ridx
      (rg-first-free var (+ ridx 1) rcount))))

;; compiler-reg-greedy-interferer-max-capped: cascade-aware, so a register
;; pinned by an over-cap resident answers evict-inf and can never be selected.
(define (rg-interferer-max-capped
  [var : i64]
  [reg-index : i64]
  [word-index : i64]
  [acc : i64]) : i64
  (if (>= word-index rg-wordcount)
    acc
    (let
      [bits : i64 (rg-ref rg-occ (+ (* reg-index rg-wordcount) word-index))]
      [best : i64 acc]
      (begin
        (while (and (not (= bits 0)) (< best rg-evict-inf))
          (let
            [other : i64 (+ (* word-index rg-word-bits) (rg-low-bit-nz bits))]
            (begin
              (when
                (and (not (= other var)) (rg-vars-interfere? var other))
                (let
                  [ec : i64
                    (if (< other rg-vars)
                      (rg-ref rg-evict other)
                      0)]
                  [weight : i64
                    (if (< other rg-vars)
                      (rg-key-weight (rg-ref rg-key other))
                      0)]
                  (if (>= ec rg-evict-cap)
                    (set! best rg-evict-inf)
                    (when (> weight best) (set! best weight)))))
              (set! bits (bit-and bits (- bits 1))))))
        (if (>= best rg-evict-inf)
          best
          (rg-interferer-max-capped var reg-index (+ word-index 1) best))))))

;; compiler-reg-greedy-first-evictable: the first pool register all of whose
;; interferers are strictly lower weight and none over the cascade cap.
(define (rg-first-evictable
  [var : i64]
  [weight : i64]
  [ridx : i64]
  [rcount : i64]) : i64
  (if (>= ridx rcount)
    -1
    (let
      [m : i64 (rg-interferer-max-capped var ridx 0 -1)]
      (if (and
        (not (rg-forbidden? (rg-ref rg-pool-reg ridx)))
        (>= m 0)
        (< m weight))
        ridx
        (rg-first-evictable var weight (+ ridx 1) rcount)))))

;; compiler-reg-greedy-heap-*: a binary max-heap over (weight desc, var asc),
;; the exact total order the O(n) pending scan selected.
(define (rg-heap-better? [a : i64] [b : i64]) : bool
  (let
    [wa : i64
      (if (< a rg-vars)
        (rg-ref rg-key a)
        0)]
    [wb : i64
      (if (< b rg-vars)
        (rg-ref rg-key b)
        0)]
    (if (> wa wb)
      true
      (if (= wa wb)
        (< a b)
        false))))

(define (rg-heap-swap! [a : i64] [b : i64]) : unit
  (let
    [t : i64 (rg-ref rg-heap a)]
    (begin
      (rg-set! rg-heap a (rg-ref rg-heap b))
      (rg-set! rg-heap b t))))

(define (rg-heap-sift-up! [index : i64]) : unit
  (if (<= index 0)
    unit
    (let
      [parent : i64 (shr (- index 1) 1)]
      (if (rg-heap-better? (rg-ref rg-heap index) (rg-ref rg-heap parent))
        (begin
          (rg-heap-swap! index parent)
          (rg-heap-sift-up! parent))
        unit))))

(define (rg-heap-sift-down! [len : i64] [index : i64]) : unit
  (let
    [left : i64 (+ (* index 2) 1)]
    [right : i64 (+ (* index 2) 2)]
    (if (>= left len)
      unit
      (let
        [best : i64
          (if (rg-heap-better? (rg-ref rg-heap left) (rg-ref rg-heap index))
            left
            index)]
        [best2 : i64
          (if (and
            (< right len)
            (rg-heap-better? (rg-ref rg-heap right) (rg-ref rg-heap best)))
            right
            best)]
        (if (= best2 index)
          unit
          (begin
            (rg-heap-swap! index best2)
            (rg-heap-sift-down! len best2)))))))

(define (rg-heap-push! [v : i64]) : unit
  (let
    [index : i64 rg-heap-len]
    (begin
      (rg-set! rg-heap index v)
      (set! rg-heap-len (+ index 1))
      (rg-heap-sift-up! index))))

;; The pending array stays authoritative for membership: entries it no longer
;; marks are lazily discarded on pop, so evict-requeue needs no decrease-key.
(define (rg-heap-pop!) : i64
  (if (<= rg-heap-len 0)
    -1
    (let
      [top : i64 (rg-ref rg-heap 0)]
      [last-index : i64 (- rg-heap-len 1)]
      (begin
        (rg-set! rg-heap 0 (rg-ref rg-heap last-index))
        (set! rg-heap-len last-index)
        (when (> last-index 0) (rg-heap-sift-down! last-index 0))
        (if (and (>= top 0) (< top rg-vars) (= (rg-ref rg-pending top) 1))
          top
          (rg-heap-pop!))))))

;; compiler-reg-greedy-evict-requeue!: unassign every interfering resident of
;; `reg-index`, re-enqueue it at its own priority and bump its cascade count.
(define (rg-evict-requeue! [var : i64] [reg-index : i64] [word-index : i64]) : unit
  (if (>= word-index rg-wordcount)
    unit
    (let
      [bits : i64 (rg-ref rg-occ (+ (* reg-index rg-wordcount) word-index))]
      (begin
        (while (not (= bits 0))
          (let
            [other : i64 (+ (* word-index rg-word-bits) (rg-low-bit-nz bits))]
            (begin
              (when
                (and (not (= other var)) (rg-vars-interfere? var other))
                (begin
                  (rg-assign-unassign! other)
                  (when
                    (< other rg-vars)
                    (begin
                      (rg-set! rg-pending other 1)
                      (rg-heap-push! other)
                      (rg-set! rg-evict other (+ (rg-ref rg-evict other) 1))))
                  (set! rg-evictions (+ rg-evictions 1))))
              (set! bits (bit-and bits (- bits 1))))))
        (rg-evict-requeue! var reg-index (+ word-index 1))))))

;; compiler-reg-greedy-arg-pref-reg: an outgoing call argument tries its ABI
;; argument register first, free-only, never evicting.
(define (rg-arg-pref-reg [var : i64] [csr-only : bool]) : i64
  (if csr-only
    -1
    (let
      [idx : i64 (rg-ref rg-argpref var)]
      (if (or (< idx 0) (>= idx rg-pool-count))
        -1
        (if (and
          (not (rg-forbidden? (rg-ref rg-pool-reg idx)))
          (rg-reg-free? var idx))
          idx
          -1)))))

;; compiler-reg-greedy-hint-free-reg: bias a root onto its move partner's
;; register when that register is in the allowed bank and free for the root.
(define (rg-hint-free-reg [var : i64]) : i64
  (let
    [nb : i64 (rg-ref rg-hint var)]
    (if (or (< nb 0) (>= nb rg-vars))
      -1
      (if (and (= (rg-ref rg-present nb) 1) (= (rg-ref rg-kind nb) 1))
        (let
          [r : i64 (rg-ref rg-reg nb)]
          [reg-index : i64 (rg-pool-index r)]
          (if (and
            (>= reg-index 0)
            (not (rg-forbidden? r))
            (rg-hint-allowed? r)
            (rg-reg-free? var reg-index))
            reg-index
            -1))
        -1))))

;; compiler-reg-greedy-alloc-one!: allocate one root and return its terminal
;; RS_* stage. A call-spanning or parameter root is restricted to callee-saved
;; homes; a div/shift-spanning root only loses the registers that op clobbers.
(define (rg-alloc-one! [var : i64]) : i64
  (if (or (= (rg-ref rg-present var) 1) (= (rg-ref rg-group var) 1))
    rg-stage-new
    (let
      [spans-call : bool (rg-var-spans-clobber? var (& rg-callbits))]
      [spans-div : bool (rg-var-spans-clobber? var (& rg-divbits))]
      [spans-shift : bool (rg-var-spans-clobber? var (& rg-shiftbits))]
      [is-param : bool (= (rg-ref rg-param var) 1)]
      [csr-only : bool (or spans-call is-param)]
      [start-idx : i64
        (if csr-only
          rg-caller-saved-count
          0)]
      (begin
        (set! rg-hint-start start-idx)
        (set! rg-forb-count 0)
        (when
          (not csr-only)
          (begin
            (when
              spans-shift
              (begin
                (rg-set! rg-forb rg-forb-count rg-id-rcx)
                (set! rg-forb-count (+ rg-forb-count 1))))
            (when
              spans-div
              (begin
                (rg-set! rg-forb rg-forb-count rg-id-rax)
                (set! rg-forb-count (+ rg-forb-count 1))
                (rg-set! rg-forb rg-forb-count rg-id-rdx)
                (set! rg-forb-count (+ rg-forb-count 1))))))
        (let
          [pref : i64 (rg-arg-pref-reg var csr-only)]
          [hint : i64 (rg-hint-free-reg var)]
          [chosen : i64
            (if (>= pref 0)
              pref
              hint)]
          (if (>= chosen 0)
            (begin
              (rg-assign-register! var chosen)
              (set! rg-assigned (+ rg-assigned 1))
              rg-stage-assign)
            (let
              [free : i64 (rg-first-free var start-idx rg-pool-count)]
              (if (>= free 0)
                (begin
                  (rg-assign-register! var free)
                  (set! rg-assigned (+ rg-assigned 1))
                  rg-stage-assign)
                (let
                  [weight : i64 (rg-key-weight (rg-ref rg-key var))]
                  [ev : i64
                    (rg-first-evictable var weight start-idx rg-pool-count)]
                  (if (>= ev 0)
                    (begin
                      (rg-evict-requeue! var ev 0)
                      (rg-assign-register! var ev)
                      (set! rg-assigned (+ rg-assigned 1))
                      rg-stage-assign)
                    (begin
                      (rg-assign-spill! var)
                      (set! rg-spilled (+ rg-spilled 1))
                      (if (not
                        (= (rg-ref rg-seg-lo var) (rg-ref rg-seg-hi var)))
                        (begin
                          (set! rg-splits (+ rg-splits 1))
                          rg-stage-split)
                        rg-stage-spill))))))))))))

;; compiler-reg-greedy-worklist-seed!: mark every collected root pending.
(define (rg-worklist-seed! [i : i64] [count : i64]) : unit
  (if (>= i count)
    unit
    (begin
      (let
        [v : i64 (rg-ref rg-order i)]
        (when
          (and (>= v 0) (< v rg-vars))
          (begin
            (rg-set! rg-pending v 1)
            (rg-heap-push! v))))
      (rg-worklist-seed! (+ i 1) count))))

;; compiler-reg-greedy-worklist-run!: pop the highest-weight pending root,
;; dequeue it, run selectOrSplit, record its terminal stage, repeat.
(define (rg-worklist-run!) : unit
  (let
    [v : i64 (rg-heap-pop!)]
    (if (< v 0)
      unit
      (begin
        (rg-set! rg-pending v 0)
        (let
          [stg : i64 (rg-alloc-one! v)]
          (rg-set! rg-stage v stg))
        (rg-worklist-run!)))))

;; compiler-reg-greedy-weight-before? and the stable bottom-up merge sort
;; compiler-reg-greedy-merge-run! / -merge-pass! / -copy-range! / -sort!.
(define (rg-weight-before? [a : i64] [b : i64]) : bool
  (let
    [wa : i64
      (if (< a rg-vars)
        (rg-ref rg-key a)
        0)]
    [wb : i64
      (if (< b rg-vars)
        (rg-ref rg-key b)
        0)]
    (if (> wa wb)
      true
      (if (< wa wb)
        false
        (< a b)))))

;; Take from the right run only when its head is STRICTLY before the left head;
;; the tie goes left, which is what makes the merge stable.
(define (rg-merge-run! [from-order : bool] [lo : i64] [mid : i64] [hi : i64]) : unit
  (let
    [i : i64 lo]
    [j : i64 mid]
    [k : i64 lo]
    (while (< k hi)
      (let
        [left : i64
          (if (< i mid)
            (if from-order
              (rg-ref rg-order i)
              (rg-ref rg-sortbuf i))
            0)]
        [right : i64
          (if (< j hi)
            (if from-order
              (rg-ref rg-order j)
              (rg-ref rg-sortbuf j))
            0)]
        [take-right : bool
          (and (< j hi) (or (>= i mid) (rg-weight-before? right left)))]
        (begin
          (if take-right
            (begin
              (if from-order
                (rg-set! rg-sortbuf k right)
                (rg-set! rg-order k right))
              (set! j (+ j 1)))
            (begin
              (if from-order
                (rg-set! rg-sortbuf k left)
                (rg-set! rg-order k left))
              (set! i (+ i 1))))
          (set! k (+ k 1)))))))

(define (rg-merge-pass! [from-order : bool] [count : i64] [width : i64]) : unit
  (let
    [lo : i64 0]
    (while (< lo count)
      (let
        [mid : i64
          (if (< (+ lo width) count)
            (+ lo width)
            count)]
        [hi : i64
          (if (< (+ lo (+ width width)) count)
            (+ lo (+ width width))
            count)]
        (begin
          (rg-merge-run! from-order lo mid hi)
          (set! lo hi))))))

(define (rg-sort! [count : i64]) : unit
  (if (< count 2)
    unit
    (let
      [width : i64 1]
      [flipped : bool false]
      (begin
        (while (< width count)
          (begin
            (rg-merge-pass! (not flipped) count width)
            (set! flipped (not flipped))
            (set! width (+ width width))))
        (when
          flipped
          (let
            [i : i64 0]
            (while (< i count)
              (begin
                (rg-set! rg-order i (rg-ref rg-sortbuf i))
                (set! i (+ i 1))))))))))

;; compiler-reg-block-index-of-point: the last block whose start point is <= it.
(define (rg-block-index-of-point [point : i64]) : i64
  (let
    [lo : i64 0]
    [hi : i64 (- rg-nblocks 1)]
    [best : i64 0]
    (begin
      (while (<= lo hi)
        (let
          [mid : i64 (shr (+ lo hi) 1)]
          (if (<= (rg-ref rg-tokens (+ rg-points-base mid)) point)
            (begin
              (set! best mid)
              (set! lo (+ mid 1)))
            (set! hi (- mid 1)))))
      best)))

;; compiler-reg-priority-band-value: a value contained in ONE block is LOCAL
;; and ranks below every global, locals among themselves in start order.
(define (rg-priority-band-value [var : i64]) : i64
  (let
    [lo : i64 (rg-ref rg-seg-lo var)]
    [hi : i64 (rg-ref rg-seg-hi var)]
    (if (or (< rg-nblocks 1) (= lo hi))
      (- rg-band-span 1)
      (let
        [s : i64 (rg-ref rg-seg-start lo)]
        [e : i64 (rg-ref rg-seg-end (- hi 1))]
        (if (= (rg-block-index-of-point s) (rg-block-index-of-point e))
          (let
            [limit : i64 (- rg-local-span 1)]
            (-
              limit
              (if (> s limit)
                limit
                s)))
          (- rg-band-span 1))))))

;; compiler-reg-greedy-combine-spill-weights, with the remat discount dropped
;; so the discounted input equals the raw one, followed by
;; compiler-reg-priority-keys!.
(define (rg-build-keys!) : unit
  (let
    [max-raw : i64 0]
    [v : i64 0]
    (begin
      (while (< v rg-vars)
        (begin
          (when (> (rg-ref rg-raw v) max-raw) (set! max-raw (rg-ref rg-raw v)))
          (set! v (+ v 1))))
      (set! v 0)
      (while (< v rg-vars)
        (let
          [r : i64 (rg-ref rg-raw v)]
          [d : i64
            (if (> r rg-weight-cap)
              rg-weight-cap
              r)]
          [tie : i64
            (if (= max-raw 0)
              0
              (let
                [scaled : i64 (/ (* r rg-tie-span) (+ max-raw 1))]
                (if (>= scaled rg-tie-span)
                  (- rg-tie-span 1)
                  scaled)))]
          (begin
            (rg-set! rg-key v (+ (* d rg-tie-span) tie))
            (set! v (+ v 1)))))
      (set! v 0)
      (while (< v rg-vars)
        (begin
          (rg-set!
            rg-key
            v
            (+ (* (rg-ref rg-key v) rg-band-span) (rg-priority-band-value v)))
          (set! v (+ v 1)))))))

;; compiler-reg-assignment-table-location-conflicts?, run over the finished
;; plan: no two vars holding one register may have overlapping segments.
(define (rg-count-conflicts) : i64
  (let
    [conflicts : i64 0]
    [reg-index : i64 0]
    (begin
      (while (< reg-index rg-pool-count)
        (let
          [count : i64 0]
          [word-index : i64 0]
          (begin
            (while (< word-index rg-wordcount)
              (let
                [bits : i64
                  (rg-ref rg-occ (+ (* reg-index rg-wordcount) word-index))]
                (begin
                  (while (not (= bits 0))
                    (begin
                      (rg-set!
                        rg-residents
                        count
                        (+ (* word-index rg-word-bits) (rg-low-bit-nz bits)))
                      (set! count (+ count 1))
                      (set! bits (bit-and bits (- bits 1)))))
                  (set! word-index (+ word-index 1)))))
            (let
              [a : i64 0]
              (while (< a count)
                (let
                  [b : i64 (+ a 1)]
                  (begin
                    (while (< b count)
                      (begin
                        (when
                          (rg-vars-interfere?
                            (rg-ref rg-residents a)
                            (rg-ref rg-residents b))
                          (set! conflicts (+ conflicts 1)))
                        (set! b (+ b 1))))
                    (set! a (+ a 1))))))
            (set! reg-index (+ reg-index 1)))))
      conflicts)))

;; Read one function's record out of the token tape into the reusable arrays.
;; This is the per-function state the compiler rebuilds for every function: the
;; interval index, the spill-weight array, the clobber point sets, the
;; assignment table and the occupancy.
(define (rg-load-function [offset : i64]) : unit
  (let
    [ncall : i64 (rg-ref rg-tokens (+ offset 3))]
    [ndiv : i64 (rg-ref rg-tokens (+ offset 4))]
    [nshift : i64 (rg-ref rg-tokens (+ offset 5))]
    [cursor : i64 0]
    [fill : i64 0]
    [v : i64 0]
    [i : i64 0]
    (begin
      (set! rg-vars (rg-ref rg-tokens offset))
      (set! rg-nblocks (rg-ref rg-tokens (+ offset 1)))
      (set! rg-ncand (rg-ref rg-tokens (+ offset 2)))
      (set! rg-nrows (rg-ref rg-tokens (+ offset 7)))
      (set! rg-points-base (+ offset 8))
      (set! rg-cand-base (+ rg-points-base (+ rg-nblocks 1)))
      (set! rg-wordcount (shr (+ rg-vars 31) 5))
      (set!
        rg-clobber-words
        (+ (shr (rg-ref rg-tokens (+ rg-points-base rg-nblocks)) 5) 1))
      (while (< v rg-vars)
        (begin
          (rg-set! rg-seg-lo v 0)
          (rg-set! rg-seg-hi v 0)
          (rg-set! rg-raw v 0)
          (rg-set! rg-key v 0)
          (rg-set! rg-hint v -1)
          (rg-set! rg-argpref v -1)
          (rg-set! rg-param v 0)
          (rg-set! rg-group v 0)
          (rg-set! rg-present v 0)
          (rg-set! rg-kind v 0)
          (rg-set! rg-reg v -1)
          (rg-set! rg-primary v -1)
          (rg-set! rg-secondary v -1)
          (rg-set! rg-pending v 0)
          (rg-set! rg-evict v 0)
          (rg-set! rg-stage v 0)
          (set! v (+ v 1))))
      (set! i 0)
      (while (< i (* rg-pool-count rg-wordcount))
        (begin
          (rg-set! rg-occ i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i rg-pool-count)
        (begin
          (rg-set! rg-ucount i 0)
          (rg-set! rg-ucoarse i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i rg-clobber-words)
        (begin
          (rg-set! rg-callbits i 0)
          (rg-set! rg-divbits i 0)
          (rg-set! rg-shiftbits i 0)
          (set! i (+ i 1))))
      (set! cursor (+ rg-cand-base rg-ncand))
      (set! i 0)
      (while (< i ncall)
        (let
          [p : i64 (rg-ref rg-tokens (+ cursor i))]
          (begin
            (rg-set!
              rg-callbits
              (shr p 5)
              (bit-or (rg-ref rg-callbits (shr p 5)) (shl 1 (bit-and p 31))))
            (set! i (+ i 1)))))
      (set! cursor (+ cursor ncall))
      (set! i 0)
      (while (< i ndiv)
        (let
          [p : i64 (rg-ref rg-tokens (+ cursor i))]
          (begin
            (rg-set!
              rg-divbits
              (shr p 5)
              (bit-or (rg-ref rg-divbits (shr p 5)) (shl 1 (bit-and p 31))))
            (set! i (+ i 1)))))
      (set! cursor (+ cursor ndiv))
      (set! i 0)
      (while (< i nshift)
        (let
          [p : i64 (rg-ref rg-tokens (+ cursor i))]
          (begin
            (rg-set!
              rg-shiftbits
              (shr p 5)
              (bit-or (rg-ref rg-shiftbits (shr p 5)) (shl 1 (bit-and p 31))))
            (set! i (+ i 1)))))
      (set! cursor (+ cursor nshift))
      (set! i 0)
      (while (< i rg-nrows)
        (let
          [var : i64 (rg-ref rg-tokens cursor)]
          [k : i64 (rg-ref rg-tokens (+ cursor 1))]
          [s : i64 0]
          (begin
            (rg-set! rg-seg-lo var fill)
            (while (< s k)
              (begin
                (rg-set!
                  rg-seg-start
                  fill
                  (rg-ref rg-tokens (+ cursor (+ 2 (* s 2)))))
                (rg-set!
                  rg-seg-end
                  fill
                  (rg-ref rg-tokens (+ cursor (+ 3 (* s 2)))))
                (set! fill (+ fill 1))
                (set! s (+ s 1))))
            (rg-set! rg-seg-hi var fill)
            (rg-set! rg-raw var (rg-ref rg-tokens (+ cursor (+ 2 (* k 2)))))
            (rg-set! rg-hint var (rg-ref rg-tokens (+ cursor (+ 3 (* k 2)))))
            (rg-set! rg-argpref var (rg-ref rg-tokens (+ cursor (+ 4 (* k 2)))))
            (rg-set! rg-param var (rg-ref rg-tokens (+ cursor (+ 5 (* k 2)))))
            (set! cursor (+ cursor (+ 6 (* k 2))))
            (set! i (+ i 1))))))))

;; One function's greedy allocation: build the priority keys, collect the
;; candidate roots in candidate order, sort them, seed the worklist and run it,
;; then verify and fold the plan.
(define (rg-run-function [offset : i64]) : i64
  (let
    [hash : i64 rg-hash-basis]
    [i : i64 0]
    [spans : i64 0]
    [conflicts : i64 0]
    (begin
      (rg-load-function offset)
      (rg-build-keys!)
      (set! rg-assigned 0)
      (set! rg-spilled 0)
      (set! rg-splits 0)
      (set! rg-evictions 0)
      (set! rg-heap-len 0)
      (while (< i rg-ncand)
        (begin
          (rg-set! rg-order i (rg-ref rg-tokens (+ rg-cand-base i)))
          (set! i (+ i 1))))
      (rg-sort! rg-ncand)
      (rg-worklist-seed! 0 rg-ncand)
      (rg-worklist-run!)
      (set! i 0)
      (while (< i rg-vars)
        (begin
          (when
            (and
              (not (= (rg-ref rg-seg-lo i) (rg-ref rg-seg-hi i)))
              (rg-var-spans-clobber? i (& rg-callbits)))
            (set! spans (+ spans 1)))
          (set! i (+ i 1))))
      (set! rg-spans-seen (+ rg-spans-seen spans))
      (when (= rg-verify 1) (set! conflicts (rg-count-conflicts)))
      (set! hash (rg-mix hash rg-vars))
      (set! hash (rg-mix hash rg-ncand))
      (set! hash (rg-mix hash rg-assigned))
      (set! hash (rg-mix hash rg-spilled))
      (set! hash (rg-mix hash rg-splits))
      (set! hash (rg-mix hash rg-evictions))
      (set! hash (rg-mix hash spans))
      (set! hash (rg-mix hash conflicts))
      (set! i 0)
      (while (< i rg-ncand)
        (let
          [v : i64 (rg-ref rg-tokens (+ rg-cand-base i))]
          (begin
            (set! hash (rg-mix hash (rg-ref rg-stage v)))
            (set! hash (rg-mix hash (rg-ref rg-kind v)))
            (set! hash (rg-mix hash (rg-ref rg-reg v)))
            (set! i (+ i 1)))))
      hash)))

(define (rg-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [functions : i64 0]
    [expected-spans : i64 0]
    [cursor : i64 3]
    [max-vars : i64 1]
    [max-segs : i64 1]
    [max-words : i64 1]
    [max-point : i64 1]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 rg-hash-basis]
    (begin
      (set! rg-tokens (rg-zero-vec capacity))
      (set! acc (rg-mix acc (rg-scan-ints text (&mut rg-tokens))))
      (set! functions (rg-ref rg-tokens 1))
      (set! expected-spans (rg-ref rg-tokens 2))
      (set! rg-offsets (rg-zero-vec (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [vars : i64 (rg-ref rg-tokens cursor)]
            [nblocks : i64 (rg-ref rg-tokens (+ cursor 1))]
            [ncand : i64 (rg-ref rg-tokens (+ cursor 2))]
            [ncall : i64 (rg-ref rg-tokens (+ cursor 3))]
            [ndiv : i64 (rg-ref rg-tokens (+ cursor 4))]
            [nshift : i64 (rg-ref rg-tokens (+ cursor 5))]
            [nseg : i64 (rg-ref rg-tokens (+ cursor 6))]
            [nrows : i64 (rg-ref rg-tokens (+ cursor 7))]
            [point : i64 (rg-ref rg-tokens (+ (+ cursor 8) nblocks))]
            [p : i64 0]
            [r : i64 0]
            (begin
              (rg-set! rg-offsets f cursor)
              (when (> vars max-vars) (set! max-vars vars))
              (when (> nseg max-segs) (set! max-segs nseg))
              (when (> point max-point) (set! max-point point))
              (set!
                p
                (+
                  (+ (+ cursor 8) (+ nblocks 1))
                  (+ ncand (+ ncall (+ ndiv nshift)))))
              (while (< r nrows)
                (begin
                  (set! p (+ p (+ 6 (* (rg-ref rg-tokens (+ p 1)) 2))))
                  (set! r (+ r 1))))
              (set! cursor p)
              (set! f (+ f 1))))))
      (set! max-words (shr (+ max-vars 31) 5))
      (set! rg-lowbit (rg-zero-vec 32))
      (set! rg-pool-reg (rg-zero-vec rg-pool-count))
      (set! rg-pool-idx (rg-zero-vec rg-pool-index-capacity))
      (rg-lowbit-init!)
      (rg-pool-init!)
      (set! rg-seg-lo (rg-zero-vec (+ max-vars 1)))
      (set! rg-seg-hi (rg-zero-vec (+ max-vars 1)))
      (set! rg-seg-start (rg-zero-vec (+ max-segs 1)))
      (set! rg-seg-end (rg-zero-vec (+ max-segs 1)))
      (set! rg-raw (rg-zero-vec (+ max-vars 1)))
      (set! rg-key (rg-zero-vec (+ max-vars 1)))
      (set! rg-hint (rg-zero-vec (+ max-vars 1)))
      (set! rg-argpref (rg-zero-vec (+ max-vars 1)))
      (set! rg-param (rg-zero-vec (+ max-vars 1)))
      (set! rg-group (rg-zero-vec (+ max-vars 1)))
      (set! rg-present (rg-zero-vec (+ max-vars 1)))
      (set! rg-kind (rg-zero-vec (+ max-vars 1)))
      (set! rg-reg (rg-zero-vec (+ max-vars 1)))
      (set! rg-primary (rg-zero-vec (+ max-vars 1)))
      (set! rg-secondary (rg-zero-vec (+ max-vars 1)))
      (set! rg-pending (rg-zero-vec (+ max-vars 1)))
      (set! rg-evict (rg-zero-vec (+ max-vars 1)))
      (set! rg-stage (rg-zero-vec (+ max-vars 1)))
      (set! rg-order (rg-zero-vec (+ max-vars 1)))
      (set! rg-sortbuf (rg-zero-vec (+ max-vars 1)))
      (set! rg-residents (rg-zero-vec (+ max-vars 1)))
      (set! rg-heap (rg-zero-vec (+ (* max-vars 5) 16)))
      (set! rg-occ (rg-zero-vec (+ (* rg-pool-count max-words) 1)))
      (set! rg-ustride (* (+ max-segs 1) rg-entry-words))
      (set! rg-union (rg-zero-vec (+ (* rg-pool-count rg-ustride) 1)))
      (set! rg-ucount (rg-zero-vec rg-pool-count))
      (set! rg-ucoarse (rg-zero-vec rg-pool-count))
      (set! rg-callbits (rg-zero-vec (+ (shr max-point 5) 2)))
      (set! rg-divbits (rg-zero-vec (+ (shr max-point 5) 2)))
      (set! rg-shiftbits (rg-zero-vec (+ (shr max-point 5) 2)))
      (set! rg-forb (rg-zero-vec 8))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          (begin
            (set!
              rg-verify
              (if (= round 0)
                1
                0))
            (set! acc (rg-mix acc round))
            (while (< step functions)
              (begin
                (set! index (+ start step))
                (when (>= index functions) (set! index (- index functions)))
                (set!
                  acc
                  (rg-mix acc (rg-run-function (rg-ref rg-offsets index))))
                (set! step (+ step 1))))
            (set! start (+ start 1))
            (when (>= start functions) (set! start 0))
            (set! round (+ round 1)))))
      (rg-mix acc (- rg-spans-seen (* expected-spans rounds))))))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (rg-bench path rounds))
      0)))