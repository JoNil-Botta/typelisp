;# benchmarks/gvn_table/bench.tl - optimizer load-CSE table scan.
;#
;# Equivalent to benchmarks/gvn_table/baseline.c. The kernel is the TypeLisp
;# optimizer's block-local redundant-load elimination: the per-instruction
;# dispatch that drives a linked-list load table, an alias-fact hash map and a
;# dense pointer-kind environment. It runs over real instruction tapes the
;# compiler produced while compiling itself, captured at `--dump-ir after-ssa`,
;# the dump point immediately before the `gvn` pass (see README.md).
;#
;# Mirrored compiler functions, all in src/compiler_optimize.tl:
;#   opt-load-cse-dispatch            -- the per-instruction switch
;#   opt-load-cse-core-load           -- lookup, rewrite-to-mov, record
;#   opt-load-cse-state-store         -- classify, granular filter, forward
;#   opt-load-cse-state-copy-bytes    -- classify both ends, field transfer
;#   opt-load-cse-state-direct-call   -- memory-read calls keep the table
;#   opt-load-cse-state-clear-for-memory / -step-other
;#   opt-load-key-for-address, opt-load-key-eq, opt-load-key-uses-var?
;#   opt-load-table-lookup / -bind / -len / -remove-key-scan
;#   opt-load-table-invalidate-var / -mentions-var?
;#   opt-load-table-filter-store, opt-load-entry-survives-store?,
;#     opt-load-entry-survives-store-location?, opt-load-ranges-disjoint?,
;#     opt-load-entry-precedes-fresh-alloc?
;#   opt-load-table-transfer-copy-fields, opt-load-copy-entry-within?
;#   opt-load-classify-store, opt-load-loc-kind-encode / -decode,
;#     opt-load-loc-field-checked, opt-load-loc-scaled-field-checked
;#   opt-load-kinds-step / -bind / -remove / -invalidate-def /
;#     -dense-drop-base-from / -dense-ref-add-kind!
;#   opt-load-alias-update-facts, opt-alias-update-value-facts,
;#     opt-alias-copy-var, opt-alias-derive-var, opt-alias-root-of-var,
;#     opt-alias-store-root-disjoint?, opt-alias-kind-encode / -decode
;#   opt-load-subword-store-forward-value, opt-load-subword-forward-const,
;#     opt-load-table-has-value-with-type?, opt-copy-safe-source?
;#   opt-load-cse-table-cap-for-size / -kinds-cap-for-size (the caps)
;#
;# KEPT: the whole block-local state machine. The load table is the compiler's
;# singly linked list of (key, value, allocation epoch) entries with the same
;# size cap, the same prepend-on-bind rule, the same whole-spine rebuild on
;# every invalidation, and the same O(n) length walk before a fresh bind. The
;# alias facts are an open-addressing i64 -> i64 map with stdlib/hashmap.tl's
;# exact policy: power-of-two capacity, `key * 6364136223846793005` hash, linear
;# probing, tombstones on remove, and growth once `(len + deleted) * 4 >=
;# capacity * 3`. The pointer kinds are the dense generation-stamped workspace
;# with the active-var vector and the base refcounts, and the same packed
;# encoding (spelled with shifts and masks here; every component is a power of
;# two, so this is the compiler's `/` and `%` arithmetic exactly).
;#
;# DROPPED, and why the kept part dominates: (1) the pass is block-local, so
;# the cross-block driver's per-edge state clone and `opt-load-cse-state-
;# intersect` join are not modelled -- joins run once per CFG edge while the
;# dispatch runs once per instruction, and every table/facts/kinds operation the
;# join would perform is already on the per-instruction path; (2) the GVN
;# stability gate (`gated?`) is false on the block-local path, which is the path
;# this tape reproduces; (3) the callee memory-summary map is empty on the
;# block-local path, so a call takes the `LookupMissing` arm exactly as it does
;# in `opt-load-copy-instr-seq-rewrite!`; (4) instruction VALUES are not
;# rewritten -- the kernel counts the rewrites the compiler would perform
;# instead of allocating replacement IR; (5) the header set is precomputed by
;# the exporter, because the compiler also builds it in one pre-pass per
;# function rather than inside the dispatch; (6) literal store values collapse
;# to one identity, which only reaches `opt-load-subword-forward-const`, a
;# constant-normalizing path that never consults the table.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold over per-block (hits, misses, invalidations, final table size)
;# with no division, so the printed decimal matches the C baseline's `%lld` bit
;# for bit.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define gvn-hash-basis : i64
  1469598103934665603)
(define gvn-hash-prime : i64
  1099511628211)

;; opt-load-cse-table-cap-floor / -kinds-cap-floor / -cap-hard-max /
;; -cap-scale-divisor
(define gvn-table-cap-floor : i64
  128)
(define gvn-kinds-cap-floor : i64
  96)
(define gvn-cap-hard-max : i64
  2048)

;; opt-load-loc-kind-* packing limits.
(define gvn-field-base-limit : i64
  1073741824)
(define gvn-field-offset-limit : i64
  1048576)
(define gvn-field-width-limit : i64
  512)

;; Instruction opcodes in the corpus tape.
(define gvn-op-other : i64
  0)
(define gvn-op-gep : i64
  1)
(define gvn-op-load : i64
  2)
(define gvn-op-store : i64
  3)
(define gvn-op-call : i64
  4)
(define gvn-op-mov : i64
  5)
(define gvn-op-alloc : i64
  6)
(define gvn-op-clearall : i64
  7)
(define gvn-op-copy : i64
  8)
(define gvn-op-cast : i64
  9)
(define gvn-op-mayalias : i64
  10)

;; Corpus.
(define gvn-tokens : (Array i64)
  (array.make-array i64 1))
(define gvn-offsets : (Array i64)
  (array.make-array i64 1))
(define gvn-ty-width : (Array i64)
  (array.make-array i64 1))
(define gvn-ty-int : (Array i64)
  (array.make-array i64 1))

;; opt-load-header-set-from-function, precomputed per function.
(define gvn-header : (Array i64)
  (array.make-array i64 1))

;; Dense pointer-kind workspace (OptLoadKindsDenseWork).
(define gvn-kinds : (Array i64)
  (array.make-array i64 1))
(define gvn-kind-stamps : (Array i64)
  (array.make-array i64 1))
(define gvn-kind-pos : (Array i64)
  (array.make-array i64 1))
(define gvn-refs : (Array i64)
  (array.make-array i64 1))
(define gvn-ref-stamps : (Array i64)
  (array.make-array i64 1))
(define gvn-active : (Array i64)
  (array.make-array i64 1))
(define gvn-kinds-len : i64
  0)
(define gvn-kinds-gen : i64
  1)
(define gvn-kinds-cap : i64
  96)

;; Alias facts: stdlib/hashmap.tl's scalar i64 -> i64 open-addressing map.
(define gvn-fact-key : (Array i64)
  (array.make-array i64 1))
(define gvn-fact-val : (Array i64)
  (array.make-array i64 1))
(define gvn-fact-state : (Array i64)
  (array.make-array i64 1))
(define gvn-fact-scratch-key : (Array i64)
  (array.make-array i64 1))
(define gvn-fact-scratch-val : (Array i64)
  (array.make-array i64 1))
(define gvn-fact-cap : i64
  32)
(define gvn-fact-len : i64
  0)
(define gvn-fact-deleted : i64
  0)

;; Load table (OptLoadTable): a singly linked list over a node pool with a free
;; list, so a rebuilt spine costs one allocation per surviving entry exactly as
;; the compiler's `Cons` rebuild does.
(define gvn-node-kind : (Array i64)
  (array.make-array i64 1))
(define gvn-node-a : (Array i64)
  (array.make-array i64 1))
(define gvn-node-b : (Array i64)
  (array.make-array i64 1))
(define gvn-node-ty : (Array i64)
  (array.make-array i64 1))
(define gvn-node-width : (Array i64)
  (array.make-array i64 1))
(define gvn-node-hdr : (Array i64)
  (array.make-array i64 1))
(define gvn-node-val : (Array i64)
  (array.make-array i64 1))
(define gvn-node-epoch : (Array i64)
  (array.make-array i64 1))
(define gvn-node-next : (Array i64)
  (array.make-array i64 1))
(define gvn-node-bump : i64
  0)
(define gvn-node-free : i64
  -1)
(define gvn-table : i64
  -1)
(define gvn-table-cap : i64
  128)
(define gvn-epoch : i64
  0)

;; Scratch for opt-load-table-transfer-copy-fields' source snapshot. The
;; compiler walks the persistent source list while threading a fresh output
;; list; the list is immutable, so snapshotting it first is equivalent.
(define gvn-copy-base : (Array i64)
  (array.make-array i64 1))
(define gvn-copy-off : (Array i64)
  (array.make-array i64 1))
(define gvn-copy-ty : (Array i64)
  (array.make-array i64 1))
(define gvn-copy-width : (Array i64)
  (array.make-array i64 1))
(define gvn-copy-val : (Array i64)
  (array.make-array i64 1))

;; Decoded pointer kind from the last gvn-kinds-lookup.
(define gvn-k-tag : i64
  0)
(define gvn-k-base : i64
  0)
(define gvn-k-off : i64
  0)
(define gvn-k-width : i64
  0)
(define gvn-k-hdr : i64
  0)

;; Canonical key from the last gvn-key-for-address.
(define gvn-key-kind : i64
  0)
(define gvn-key-a : i64
  0)
(define gvn-key-b : i64
  0)
(define gvn-key-ty : i64
  0)
(define gvn-key-width : i64
  0)
(define gvn-key-hdr : i64
  0)

;; Alias root from the last gvn-root-of-value.
(define gvn-root-kind : i64
  0)
(define gvn-root-id : i64
  0)
(define gvn-root-epoch : i64
  0)

;; Per-block counters folded into the checksum.
(define gvn-hits : i64
  0)
(define gvn-misses : i64
  0)
(define gvn-invalidations : i64
  0)

(define (gvn-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) gvn-hash-prime))

(define (gvn-byte-at [text : String] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (gvn-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

(define (gvn-scan-ints [text : String] [out : (Array i64)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (gvn-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (gvn-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (gvn-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (gvn-digit? (gvn-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (gvn-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (array-set!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; opt-load-cse-scaled-cap
(define (gvn-scaled-cap [floor : i64] [instrs : i64]) : i64
  (let
    [from-size : i64 (/ instrs 2)]
    [with-floor : i64
      (if (> from-size floor)
        from-size
        floor)]
    (if (> with-floor gvn-cap-hard-max)
      gvn-cap-hard-max
      with-floor)))

;; --- alias facts map --------------------------------------------------------
(define (gvn-facts-reset) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i gvn-fact-cap)
        (begin
          (array-set! gvn-fact-state i 0)
          (set! i (+ i 1))))
      (set! gvn-fact-cap 32)
      (set! gvn-fact-len 0)
      (set! gvn-fact-deleted 0))))

;; stdlib/hashmap.tl `probe`: linear probing over a power-of-two capacity, with
;; the first tombstone reused for an absent key. A non-negative result is the
;; occupied slot; `-(index + 2)` is the slot an insert would take.
(define (gvn-facts-slot [key : i64]) : i64
  (let
    [mask : i64 (- gvn-fact-cap 1)]
    [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
    [walked : i64 0]
    [first : i64 -1]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (and (< walked gvn-fact-cap) (not done))
        (let
          [state : i64 (array-ref gvn-fact-state cursor)]
          (cond
            [(= state 2)
              (if (= (array-ref gvn-fact-key cursor) key)
                (begin
                  (set! found cursor)
                  (set! done true))
                (begin
                  (set! cursor (bit-and (+ cursor 1) mask))
                  (set! walked (+ walked 1))))]
            [(= state 0)
              (begin
                (set!
                  found
                  (-
                    0
                    (+
                      2
                      (if (>= first 0)
                        first
                        cursor))))
                (set! done true))]
            [else
              (begin
                (when (< first 0) (set! first cursor))
                (set! cursor (bit-and (+ cursor 1) mask))
                (set! walked (+ walked 1)))])))
      (if done
        found
        (if (>= first 0)
          (- 0 (+ 2 first))
          -1)))))

(define (gvn-facts-grow) : unit
  (let
    [old-cap : i64 gvn-fact-cap]
    [live : i64 0]
    [i : i64 0]
    (begin
      (while (< i old-cap)
        (begin
          (when
            (= (array-ref gvn-fact-state i) 2)
            (begin
              (array-set! gvn-fact-scratch-key live (array-ref gvn-fact-key i))
              (array-set! gvn-fact-scratch-val live (array-ref gvn-fact-val i))
              (set! live (+ live 1))))
          (set! i (+ i 1))))
      (set! gvn-fact-cap (* old-cap 2))
      (set! i 0)
      (while (< i gvn-fact-cap)
        (begin
          (array-set! gvn-fact-state i 0)
          (set! i (+ i 1))))
      (set! gvn-fact-len 0)
      (set! gvn-fact-deleted 0)
      (set! i 0)
      (while (< i live)
        (let
          [slot : i64 (gvn-facts-slot (array-ref gvn-fact-scratch-key i))]
          [index : i64 (- (- 0 slot) 2)]
          (begin
            (array-set! gvn-fact-state index 2)
            (array-set! gvn-fact-key index (array-ref gvn-fact-scratch-key i))
            (array-set! gvn-fact-val index (array-ref gvn-fact-scratch-val i))
            (set! gvn-fact-len (+ gvn-fact-len 1))
            (set! i (+ i 1))))))))

(define (gvn-facts-insert [key : i64] [value : i64]) : unit
  (begin
    (when
      (>= (* (+ gvn-fact-len gvn-fact-deleted) 4) (* gvn-fact-cap 3))
      (gvn-facts-grow))
    (let
      [slot : i64 (gvn-facts-slot key)]
      (if (>= slot 0)
        (array-set! gvn-fact-val slot value)
        (let
          [index : i64 (- (- 0 slot) 2)]
          (begin
            (when
              (= (array-ref gvn-fact-state index) 1)
              (set! gvn-fact-deleted (- gvn-fact-deleted 1)))
            (array-set! gvn-fact-state index 2)
            (array-set! gvn-fact-key index key)
            (array-set! gvn-fact-val index value)
            (set! gvn-fact-len (+ gvn-fact-len 1))))))))

(define (gvn-facts-remove [key : i64]) : unit
  (let
    [slot : i64 (gvn-facts-slot key)]
    (when
      (>= slot 0)
      (begin
        (array-set! gvn-fact-state slot 1)
        (set! gvn-fact-len (- gvn-fact-len 1))
        (set! gvn-fact-deleted (+ gvn-fact-deleted 1))))))

;; --- alias kinds ------------------------------------------------------------
;; opt-alias-kind-encode: Unique(epoch) = -(6 + epoch), ExclusiveRef -2,
;; SharedRef -3, MayAlias -4, Invalidated -5, Derived(root) = root.
(define (gvn-alias-mark-may-alias [var : i64]) : unit
  (gvn-facts-insert var -4))

;; opt-alias-copy-var
(define (gvn-alias-copy-var [dst : i64] [src : i64]) : unit
  (let
    [slot : i64 (gvn-facts-slot src)]
    (if (>= slot 0)
      (let
        [code : i64 (array-ref gvn-fact-val slot)]
        (when
          (not (= dst src))
          (cond
            [(>= code 0) (gvn-facts-insert dst code)]
            [(= code -2) (gvn-facts-insert dst src)]
            [(= code -3) (gvn-facts-insert dst src)]
            [(<= code -6) (gvn-facts-insert dst src)]
            [else (gvn-alias-mark-may-alias dst)])))
      (gvn-alias-mark-may-alias dst))))

;; opt-alias-derive-var
(define (gvn-alias-derive-var [dst : i64] [base : i64]) : unit
  (let
    [slot : i64 (gvn-facts-slot base)]
    (if (>= slot 0)
      (let
        [code : i64 (array-ref gvn-fact-val slot)]
        (cond
          [(>= code 0) (gvn-facts-insert dst code)]
          [(= code -2) (gvn-facts-insert dst base)]
          [(= code -3) (gvn-facts-insert dst base)]
          [(<= code -6) (gvn-facts-insert dst base)]
          [else (gvn-alias-mark-may-alias dst)]))
      (gvn-alias-mark-may-alias dst))))

;; opt-alias-root-of-var, written into the gvn-root-* globals.
(define (gvn-root-of-var [var : i64]) : unit
  (let
    [slot : i64 (gvn-facts-slot var)]
    (begin
      (set! gvn-root-kind 0)
      (set! gvn-root-id 0)
      (set! gvn-root-epoch 0)
      (when
        (>= slot 0)
        (let
          [code : i64 (array-ref gvn-fact-val slot)]
          (cond
            [(<= code -6)
              (begin
                (set! gvn-root-kind 1)
                (set! gvn-root-id var)
                (set! gvn-root-epoch (- (- 0 code) 6)))]
            [(= code -2)
              (begin
                (set! gvn-root-kind 2)
                (set! gvn-root-id var))]
            [(= code -3)
              (begin
                (set! gvn-root-kind 3)
                (set! gvn-root-id var))]
            [(>= code 0)
              (let
                [root-slot : i64 (gvn-facts-slot code)]
                (when
                  (>= root-slot 0)
                  (let
                    [root-code : i64 (array-ref gvn-fact-val root-slot)]
                    (cond
                      [(<= root-code -6)
                        (begin
                          (set! gvn-root-kind 1)
                          (set! gvn-root-id code)
                          (set! gvn-root-epoch (- (- 0 root-code) 6)))]
                      [(= root-code -2)
                        (begin
                          (set! gvn-root-kind 2)
                          (set! gvn-root-id code))]
                      [(= root-code -3)
                        (begin
                          (set! gvn-root-kind 3)
                          (set! gvn-root-id code))]
                      [else unit]))))]
            [else unit]))))))

(define (gvn-root-of-value [value : i64]) : unit
  (if (>= value 0)
    (gvn-root-of-var value)
    (begin
      (set! gvn-root-kind 0)
      (set! gvn-root-id 0)
      (set! gvn-root-epoch 0))))

;; opt-alias-store-root-disjoint?
(define (gvn-root-disjoint?
  [store-kind : i64]
  [store-id : i64]
  [entry-kind : i64]
  [entry-id : i64]) : bool
  (if (or (= store-kind 1) (= store-kind 2))
    (if (= entry-kind 0)
      false
      (not (= store-id entry-id)))
    false))

;; --- pointer kinds ----------------------------------------------------------
;; opt-load-loc-kind-encode: 0 unknown, 1 element,
;; field = 2 + h*4 + w*8 + off*4096 + base*2^32 (even),
;; scaled = 3 + h*4 + w*8 + index*4096 + base*2^32 (odd).
(define (gvn-kind-encode
  [tag : i64]
  [base : i64]
  [off : i64]
  [width : i64]
  [hdr : i64]) : i64
  (cond
    [(= tag 0) 0]
    [(= tag 1) 1]
    [else
      (+
        (if (= tag 2)
          2
          3)
        (+ (* hdr 4) (+ (* width 8) (+ (shl off 12) (shl base 32)))))]))

;; opt-load-loc-kind-decode. Every packing scale is a power of two, so the
;; compiler's `/` and `%` are these shifts and masks exactly.
(define (gvn-kind-decode [value : i64]) : unit
  (cond
    [(= value 0)
      (begin
        (set! gvn-k-tag 0)
        (set! gvn-k-base 0)
        (set! gvn-k-off 0)
        (set! gvn-k-width 0)
        (set! gvn-k-hdr 0))]
    [(= value 1)
      (begin
        (set! gvn-k-tag 1)
        (set! gvn-k-base 0)
        (set! gvn-k-off 0)
        (set! gvn-k-width 0)
        (set! gvn-k-hdr 0))]
    [else
      (begin
        (set!
          gvn-k-tag
          (if (= (bit-and value 1) 1)
            3
            2))
        (set! gvn-k-base (shr value 32))
        (set! gvn-k-off (bit-and (shr value 12) 1048575))
        (set! gvn-k-width (bit-and (shr value 3) 511))
        (set! gvn-k-hdr (bit-and (shr value 2) 1)))]))

(define (gvn-kinds-lookup [var : i64]) : unit
  (if (or
    (< var 0)
    (>= var (array-length gvn-kinds))
    (not (= (array-ref gvn-kind-stamps var) gvn-kinds-gen)))
    (gvn-kind-decode 0)
    (gvn-kind-decode (array-ref gvn-kinds var))))

(define (gvn-kinds-ref-count [base : i64]) : i64
  (if (or
    (< base 0)
    (>= base (array-length gvn-refs))
    (not (= (array-ref gvn-ref-stamps base) gvn-kinds-gen)))
    0
    (array-ref gvn-refs base)))

(define (gvn-kinds-ref-add [base : i64] [delta : i64]) : unit
  (when
    (and (>= base 0) (< base (array-length gvn-refs)))
    (let
      [old : i64
        (if (= (array-ref gvn-ref-stamps base) gvn-kinds-gen)
          (array-ref gvn-refs base)
          0)]
      (begin
        (array-set! gvn-ref-stamps base gvn-kinds-gen)
        (array-set! gvn-refs base (+ old delta))))))

;; opt-load-kinds-dense-ref-add-kind!
(define (gvn-kinds-ref-add-kind
  [tag : i64]
  [base : i64]
  [off : i64]
  [delta : i64]) : unit
  (cond
    [(= tag 2) (gvn-kinds-ref-add base delta)]
    [(= tag 3)
      (begin
        (gvn-kinds-ref-add base delta)
        (gvn-kinds-ref-add off delta))]
    [else unit]))

;; opt-load-kinds-remove (dense arm): swap-remove from the active vector.
(define (gvn-kinds-remove [var : i64]) : unit
  (when
    (and
      (>= var 0)
      (< var (array-length gvn-kinds))
      (= (array-ref gvn-kind-stamps var) gvn-kinds-gen))
    (let
      [old : i64 (array-ref gvn-kinds var)]
      [pos : i64 (array-ref gvn-kind-pos var)]
      [last-pos : i64 (- gvn-kinds-len 1)]
      [last-var : i64 (array-ref gvn-active last-pos)]
      (begin
        (gvn-kind-decode old)
        (gvn-kinds-ref-add-kind gvn-k-tag gvn-k-base gvn-k-off -1)
        (when
          (not (= pos last-pos))
          (begin
            (array-set! gvn-active pos last-var)
            (array-set! gvn-kind-pos last-var pos)))
        (array-set! gvn-kind-stamps var 0)
        (set! gvn-kinds-len last-pos)))))

;; opt-load-kinds-bind (dense arm): Unknown removes; the env is size-capped.
(define (gvn-kinds-bind
  [var : i64]
  [tag : i64]
  [base : i64]
  [off : i64]
  [width : i64]
  [hdr : i64]) : unit
  (if (= tag 0)
    (gvn-kinds-remove var)
    (begin
      (gvn-kinds-remove var)
      (when
        (and
          (>= var 0)
          (< var (array-length gvn-kinds))
          (< gvn-kinds-len gvn-kinds-cap)
          (< gvn-kinds-len (array-length gvn-active)))
        (begin
          (gvn-kinds-ref-add-kind tag base off 1)
          (array-set! gvn-active gvn-kinds-len var)
          (array-set! gvn-kind-pos var gvn-kinds-len)
          (array-set! gvn-kinds var (gvn-kind-encode tag base off width hdr))
          (array-set! gvn-kind-stamps var gvn-kinds-gen)
          (set! gvn-kinds-len (+ gvn-kinds-len 1)))))))

;; opt-load-loc-field-checked
(define (gvn-bind-field-checked
  [var : i64]
  [base : i64]
  [off : i64]
  [width : i64]
  [hdr : i64]) : unit
  (if (and
    (>= base 0)
    (< base gvn-field-base-limit)
    (>= off 0)
    (< off gvn-field-offset-limit)
    (> width 0)
    (< width gvn-field-width-limit))
    (gvn-kinds-bind var 2 base off width hdr)
    (gvn-kinds-bind var 0 0 0 0 0)))

;; opt-load-loc-scaled-field-checked
(define (gvn-bind-scaled-checked
  [var : i64]
  [base : i64]
  [index : i64]
  [width : i64]
  [hdr : i64]) : unit
  (if (and
    (>= base 0)
    (< base gvn-field-base-limit)
    (>= index 0)
    (< index gvn-field-offset-limit)
    (> width 0)
    (< width gvn-field-width-limit))
    (gvn-kinds-bind var 3 base index width hdr)
    (gvn-kinds-bind var 0 0 0 0 0)))

;; opt-load-kinds-dense-drop-base-from
(define (gvn-kinds-drop-base [base : i64]) : unit
  (let
    [index : i64 0]
    (while (< index gvn-kinds-len)
      (let
        [bound : i64 (array-ref gvn-active index)]
        (begin
          (gvn-kinds-lookup bound)
          (if (or
            (and (= gvn-k-tag 2) (= gvn-k-base base))
            (and (= gvn-k-tag 3) (or (= gvn-k-base base) (= gvn-k-off base))))
            (gvn-kinds-remove bound)
            (set! index (+ index 1))))))))

;; opt-load-kinds-invalidate-def
(define (gvn-kinds-invalidate-def [var : i64]) : unit
  (begin
    (gvn-kinds-remove var)
    (when (> (gvn-kinds-ref-count var) 0) (gvn-kinds-drop-base var))))

(define (gvn-header-var? [var : i64]) : bool
  (if (or (< var 0) (>= var (array-length gvn-header)))
    false
    (= (array-ref gvn-header var) 1)))

;; --- load table -------------------------------------------------------------
(define (gvn-node-alloc) : i64
  (if (>= gvn-node-free 0)
    (let
      [node : i64 gvn-node-free]
      (begin
        (set! gvn-node-free (array-ref gvn-node-next node))
        node))
    (let
      [node : i64 gvn-node-bump]
      (begin
        (set! gvn-node-bump (+ gvn-node-bump 1))
        node))))

(define (gvn-node-release [head : i64]) : unit
  (let
    [node : i64 head]
    (while (>= node 0)
      (let
        [next : i64 (array-ref gvn-node-next node)]
        (begin
          (array-set! gvn-node-next node gvn-node-free)
          (set! gvn-node-free node)
          (set! node next))))))

(define (gvn-node-copy [source : i64]) : i64
  (let
    [node : i64 (gvn-node-alloc)]
    (begin
      (array-set! gvn-node-kind node (array-ref gvn-node-kind source))
      (array-set! gvn-node-a node (array-ref gvn-node-a source))
      (array-set! gvn-node-b node (array-ref gvn-node-b source))
      (array-set! gvn-node-ty node (array-ref gvn-node-ty source))
      (array-set! gvn-node-width node (array-ref gvn-node-width source))
      (array-set! gvn-node-hdr node (array-ref gvn-node-hdr source))
      (array-set! gvn-node-val node (array-ref gvn-node-val source))
      (array-set! gvn-node-epoch node (array-ref gvn-node-epoch source))
      (array-set! gvn-node-next node -1)
      node)))

;; opt-load-table-len
(define (gvn-table-len [head : i64]) : i64
  (let
    [node : i64 head]
    [count : i64 0]
    (begin
      (while (>= node 0)
        (begin
          (set! count (+ count 1))
          (set! node (array-ref gvn-node-next node))))
      count)))

;; opt-load-key-eq against the key currently in the gvn-key-* globals.
(define (gvn-key-matches? [node : i64]) : bool
  (if (not (= (array-ref gvn-node-kind node) gvn-key-kind))
    false
    (cond
      [(= gvn-key-kind 0)
        (and
          (= (array-ref gvn-node-a node) gvn-key-a)
          (= (array-ref gvn-node-ty node) gvn-key-ty)
          (= (array-ref gvn-node-b node) gvn-key-b))]
      [else
        (and
          (= (array-ref gvn-node-a node) gvn-key-a)
          (= (array-ref gvn-node-b node) gvn-key-b)
          (= (array-ref gvn-node-ty node) gvn-key-ty)
          (= (array-ref gvn-node-hdr node) gvn-key-hdr))])))

;; opt-load-table-lookup: the cached value, or -1000000 for a miss.
(define (gvn-table-lookup) : i64
  (let
    [node : i64 gvn-table]
    [result : i64 -1000000]
    (begin
      (while (and (>= node 0) (= result -1000000))
        (if (gvn-key-matches? node)
          (set! result (array-ref gvn-node-val node))
          (set! node (array-ref gvn-node-next node))))
      result)))

;; opt-load-key-uses-var?
(define (gvn-key-uses-var? [var : i64]) : bool
  (cond
    [(= gvn-key-kind 0) (and (>= gvn-key-a 0) (= gvn-key-a var))]
    [(= gvn-key-kind 1) (= gvn-key-a var)]
    [else (or (= gvn-key-a var) (= gvn-key-b var))]))

(define (gvn-node-uses-var? [node : i64] [var : i64]) : bool
  (let
    [kind : i64 (array-ref gvn-node-kind node)]
    [a : i64 (array-ref gvn-node-a node)]
    [b : i64 (array-ref gvn-node-b node)]
    (cond
      [(= kind 0) (and (>= a 0) (= a var))]
      [(= kind 1) (= a var)]
      [else (or (= a var) (= b var))])))

;; opt-load-entry-mentions-var?
(define (gvn-node-mentions-var? [node : i64] [var : i64]) : bool
  (or
    (and
      (>= (array-ref gvn-node-val node) 0)
      (= (array-ref gvn-node-val node) var))
    (gvn-node-uses-var? node var)))

;; opt-load-table-remove-key-scan: rebuild without the key in the gvn-key-*
;; globals, then release the dead spine.
(define (gvn-table-remove-key) : unit
  (let
    [node : i64 gvn-table]
    [head : i64 -1]
    [tail : i64 -1]
    (begin
      (while (>= node 0)
        (begin
          (unless
            (gvn-key-matches? node)
            (let
              [fresh : i64 (gvn-node-copy node)]
              (begin
                (if (< tail 0)
                  (set! head fresh)
                  (array-set! gvn-node-next tail fresh))
                (set! tail fresh))))
          (set! node (array-ref gvn-node-next node))))
      (gvn-node-release gvn-table)
      (set! gvn-table head))))

;; opt-load-table-bind
(define (gvn-table-bind [value : i64] [epoch : i64]) : unit
  (let
    [existing : i64 (gvn-table-lookup)]
    (begin
      (if (not (= existing -1000000))
        (gvn-table-remove-key)
        unit)
      (when
        (or
          (not (= existing -1000000))
          (< (gvn-table-len gvn-table) gvn-table-cap))
        (let
          [node : i64 (gvn-node-alloc)]
          (begin
            (array-set! gvn-node-kind node gvn-key-kind)
            (array-set! gvn-node-a node gvn-key-a)
            (array-set! gvn-node-b node gvn-key-b)
            (array-set! gvn-node-ty node gvn-key-ty)
            (array-set! gvn-node-width node gvn-key-width)
            (array-set! gvn-node-hdr node gvn-key-hdr)
            (array-set! gvn-node-val node value)
            (array-set! gvn-node-epoch node epoch)
            (array-set! gvn-node-next node gvn-table)
            (set! gvn-table node)))))))

;; opt-load-table-invalidate-var
(define (gvn-table-invalidate-var [var : i64]) : unit
  (let
    [node : i64 gvn-table]
    [mentions : bool false]
    (begin
      (while (and (>= node 0) (not mentions))
        (if (gvn-node-mentions-var? node var)
          (set! mentions true)
          (set! node (array-ref gvn-node-next node))))
      (when
        mentions
        (let
          [scan : i64 gvn-table]
          [head : i64 -1]
          [tail : i64 -1]
          (begin
            (while (>= scan 0)
              (begin
                (if (gvn-node-mentions-var? scan var)
                  (set! gvn-invalidations (+ gvn-invalidations 1))
                  (let
                    [fresh : i64 (gvn-node-copy scan)]
                    (begin
                      (if (< tail 0)
                        (set! head fresh)
                        (array-set! gvn-node-next tail fresh))
                      (set! tail fresh))))
                (set! scan (array-ref gvn-node-next scan))))
            (gvn-node-release gvn-table)
            (set! gvn-table head)))))))

;; opt-load-ranges-disjoint?
(define (gvn-ranges-disjoint?
  [alo : i64]
  [awidth : i64]
  [blo : i64]
  [bwidth : i64]) : bool
  (and
    (> awidth 0)
    (> bwidth 0)
    (or (<= (+ alo awidth) blo) (<= (+ blo bwidth) alo))))

;; opt-load-entry-survives-store-location?
(define (gvn-survives-location?
  [node : i64]
  [class : i64]
  [class-base : i64]
  [class-off : i64]
  [class-width : i64]
  [class-hdr : i64]) : bool
  (let
    [kind : i64 (array-ref gvn-node-kind node)]
    (cond
      [(= class 1) (and (= kind 1) (= (array-ref gvn-node-hdr node) 1))]
      [(= class 2)
        (cond
          [(= kind 0) (and (= (array-ref gvn-node-b node) 1) (= class-hdr 1))]
          [(= kind 1)
            (and
              (= (array-ref gvn-node-a node) class-base)
              (gvn-ranges-disjoint?
                class-off
                class-width
                (array-ref gvn-node-b node)
                (array-ref gvn-node-width node)))]
          [else false])]
      [else false])))

;; opt-load-entry-survives-store?
(define (gvn-survives-store?
  [node : i64]
  [store-kind : i64]
  [store-id : i64]
  [store-epoch : i64]
  [class : i64]
  [class-base : i64]
  [class-off : i64]
  [class-width : i64]
  [class-hdr : i64]) : bool
  (let
    [kind : i64 (array-ref gvn-node-kind node)]
    [entry-kind : i64 0]
    [entry-id : i64 0]
    (begin
      (if (= kind 0)
        (gvn-root-of-value (array-ref gvn-node-a node))
        (gvn-root-of-var (array-ref gvn-node-a node)))
      (set! entry-kind gvn-root-kind)
      (set! entry-id gvn-root-id)
      (or
        (gvn-root-disjoint? store-kind store-id entry-kind entry-id)
        (and (= store-kind 1) (< (array-ref gvn-node-epoch node) store-epoch))
        (gvn-survives-location?
          node
          class
          class-base
          class-off
          class-width
          class-hdr)))))

;; opt-load-table-filter-store
(define (gvn-table-filter-store
  [store-kind : i64]
  [store-id : i64]
  [store-epoch : i64]
  [class : i64]
  [class-base : i64]
  [class-off : i64]
  [class-width : i64]
  [class-hdr : i64]) : unit
  (let
    [node : i64 gvn-table]
    [head : i64 -1]
    [tail : i64 -1]
    (begin
      (while (>= node 0)
        (begin
          (if (gvn-survives-store?
            node
            store-kind
            store-id
            store-epoch
            class
            class-base
            class-off
            class-width
            class-hdr)
            (let
              [fresh : i64 (gvn-node-copy node)]
              (begin
                (if (< tail 0)
                  (set! head fresh)
                  (array-set! gvn-node-next tail fresh))
                (set! tail fresh)))
            (set! gvn-invalidations (+ gvn-invalidations 1)))
          (set! node (array-ref gvn-node-next node))))
      (gvn-node-release gvn-table)
      (set! gvn-table head))))

(define (gvn-table-clear) : unit
  (begin
    (set! gvn-invalidations (+ gvn-invalidations (gvn-table-len gvn-table)))
    (gvn-node-release gvn-table)
    (set! gvn-table -1)))

;; opt-load-table-has-value-with-type?
(define (gvn-table-has-value? [value : i64] [ty : i64]) : bool
  (let
    [node : i64 gvn-table]
    [found : bool false]
    (begin
      (while (and (>= node 0) (not found))
        (if (and
          (= (array-ref gvn-node-val node) value)
          (= (array-ref gvn-node-ty node) ty))
          (set! found true)
          (set! node (array-ref gvn-node-next node))))
      found)))

;; opt-load-table-transfer-copy-fields plus opt-load-copy-entry-within?. The
;; source list is snapshotted first because the compiler walks an immutable
;; persistent list while it rebuilds the output.
(define (gvn-table-transfer-copy
  [src-base : i64]
  [src-off : i64]
  [dst-base : i64]
  [dst-off : i64]
  [size : i64]
  [dst-hdr : i64]
  [epoch : i64]) : unit
  (let
    [node : i64 gvn-table]
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (>= node 0)
        (begin
          (when
            (and
              (= (array-ref gvn-node-kind node) 1)
              (= (array-ref gvn-node-a node) src-base)
              (> (array-ref gvn-node-width node) 0)
              (>= (array-ref gvn-node-b node) src-off)
              (<=
                (+ (array-ref gvn-node-b node) (array-ref gvn-node-width node))
                (+ src-off size)))
            (begin
              (array-set! gvn-copy-base count (array-ref gvn-node-a node))
              (array-set! gvn-copy-off count (array-ref gvn-node-b node))
              (array-set! gvn-copy-ty count (array-ref gvn-node-ty node))
              (array-set! gvn-copy-width count (array-ref gvn-node-width node))
              (array-set! gvn-copy-val count (array-ref gvn-node-val node))
              (set! count (+ count 1))))
          (set! node (array-ref gvn-node-next node))))
      (while (< i count)
        (begin
          (set! gvn-key-kind 1)
          (set! gvn-key-a dst-base)
          (set! gvn-key-b (+ dst-off (- (array-ref gvn-copy-off i) src-off)))
          (set! gvn-key-ty (array-ref gvn-copy-ty i))
          (set! gvn-key-width (array-ref gvn-copy-width i))
          (set! gvn-key-hdr dst-hdr)
          (gvn-table-bind (array-ref gvn-copy-val i) epoch)
          (set! i (+ i 1)))))))

;; --- per-instruction dispatch -----------------------------------------------
;; opt-load-classify-store, written into the gvn-k-* globals reinterpreted as
;; (class, base, off, width, hdr).
(define (gvn-classify-store [ptr : i64] [width : i64]) : unit
  (if (or (<= width 0) (< ptr 0))
    (begin
      (set! gvn-k-tag 0)
      (set! gvn-k-base 0)
      (set! gvn-k-off 0)
      (set! gvn-k-width 0)
      (set! gvn-k-hdr 0))
    (begin
      (gvn-kinds-lookup ptr)
      (cond
        [(= gvn-k-tag 1) (set! gvn-k-tag 1)]
        [(= gvn-k-tag 2) (set! gvn-k-width width)]
        [(= gvn-k-tag 3) (set! gvn-k-tag 1)]
        [else unit]))))

;; opt-load-key-for-address
(define (gvn-key-for-address [addr : i64] [raw : i64] [ty : i64] [width : i64]) : unit
  (begin
    (set! gvn-key-ty ty)
    (set! gvn-key-width width)
    (if (>= addr 0)
      (begin
        (gvn-kinds-lookup addr)
        (cond
          [(= gvn-k-tag 2)
            (begin
              (set! gvn-key-kind 1)
              (set! gvn-key-a gvn-k-base)
              (set! gvn-key-b gvn-k-off)
              (set! gvn-key-hdr gvn-k-hdr))]
          [(= gvn-k-tag 3)
            (begin
              (set! gvn-key-kind 2)
              (set! gvn-key-a gvn-k-base)
              (set! gvn-key-b gvn-k-off)
              (set! gvn-key-hdr gvn-k-hdr))]
          [(= gvn-k-tag 1)
            (begin
              (set! gvn-key-kind 0)
              (set! gvn-key-a addr)
              (set! gvn-key-b 1)
              (set! gvn-key-hdr 0))]
          [else
            (begin
              (set! gvn-key-kind 0)
              (set! gvn-key-a addr)
              (set! gvn-key-b 0)
              (set! gvn-key-hdr 0))]))
      (begin
        (set! gvn-key-kind 0)
        (set! gvn-key-a (- 0 (+ raw 2)))
        (set! gvn-key-b 0)
        (set! gvn-key-hdr 0)))))

;; opt-load-kinds-step
(define (gvn-kinds-step
  [op : i64]
  [dst : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : unit
  (begin
    (when (>= dst 0) (gvn-kinds-invalidate-def dst))
    (cond
      [(= op gvn-op-gep)
        (when
          (>= a 0)
          (begin
            (gvn-kinds-lookup a)
            (cond
              [(= gvn-k-tag 1)
                (if (= b 1)
                  (gvn-bind-scaled-checked dst a c d 0)
                  (gvn-kinds-bind dst 1 0 0 0 0))]
              [(= gvn-k-tag 2)
                (let
                  [base0 : i64 gvn-k-base]
                  [off0 : i64 gvn-k-off]
                  [hdr0 : i64 gvn-k-hdr]
                  (if (= b 0)
                    (when
                      (> d 0)
                      (gvn-bind-field-checked dst base0 (+ off0 (* c d)) d hdr0))
                    (when
                      (= off0 0)
                      (gvn-bind-scaled-checked dst base0 c d hdr0))))]
              [(= gvn-k-tag 3) (gvn-kinds-bind dst 1 0 0 0 0)]
              [else
                (when
                  (and (= b 0) (> d 0) (not (= a dst)))
                  (gvn-bind-field-checked
                    dst
                    a
                    (* c d)
                    d
                    (if (gvn-header-var? a)
                      1
                      0)))])))]
      [(= op gvn-op-load)
        (when
          (>= a 0)
          (begin
            (gvn-kinds-lookup a)
            (if (= gvn-k-tag 2)
              (when
                (and (= gvn-k-hdr 1) (= gvn-k-off 0) (= c 8))
                (gvn-kinds-bind dst 1 0 0 0 0))
              (when
                (and (gvn-header-var? a) (= c 8))
                (gvn-kinds-bind dst 1 0 0 0 0)))))]
      [(= op gvn-op-mov)
        (when
          (>= a 0)
          (begin
            (gvn-kinds-lookup a)
            (cond
              [(= gvn-k-tag 1) (gvn-kinds-bind dst 1 0 0 0 0)]
              [(= gvn-k-tag 2)
                (gvn-kinds-bind
                  dst
                  2
                  gvn-k-base
                  gvn-k-off
                  gvn-k-width
                  gvn-k-hdr)]
              [(= gvn-k-tag 3)
                (gvn-kinds-bind
                  dst
                  3
                  gvn-k-base
                  gvn-k-off
                  gvn-k-width
                  gvn-k-hdr)]
              [else unit])))]
      [else unit])))

;; opt-load-alias-update-facts / opt-alias-update-value-facts
(define (gvn-alias-step
  [op : i64]
  [dst : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [epoch : i64]) : unit
  (cond
    [(= op gvn-op-load)
      (begin
        (when (>= dst 0) (gvn-facts-remove dst))
        (if (>= a 0)
          (begin
            (gvn-kinds-lookup a)
            (if (and (= gvn-k-tag 2) (= gvn-k-hdr 1) (= gvn-k-off 0) (= c 8))
              (gvn-alias-derive-var dst a)
              (gvn-alias-mark-may-alias dst)))
          (gvn-alias-mark-may-alias dst)))]
    [else
      (begin
        (when (>= dst 0) (gvn-facts-remove dst))
        (cond
          [(= op gvn-op-alloc)
            (when (>= dst 0) (gvn-facts-insert dst (- 0 (+ 6 epoch))))]
          [(= op gvn-op-gep)
            (if (>= a 0)
              (gvn-alias-derive-var dst a)
              (gvn-alias-mark-may-alias dst))]
          [(= op gvn-op-mov)
            (if (>= a 0)
              (gvn-alias-copy-var dst a)
              (gvn-alias-mark-may-alias dst))]
          [(= op gvn-op-cast)
            (if (>= a 0)
              (gvn-alias-copy-var dst a)
              (gvn-alias-mark-may-alias dst))]
          [(= op gvn-op-call)
            (when
              (and (= b 1) (>= dst 0))
              (gvn-facts-insert dst (- 0 (+ 6 epoch))))]
          [(= op gvn-op-mayalias) (gvn-alias-mark-may-alias dst)]
          [else unit]))]))

;; opt-load-subword-store-forward-value: -1000000 is "no forward",
;; -2 is a normalized copy-safe literal.
(define (gvn-subword-forward [value : i64] [ty : i64] [width : i64]) : i64
  (cond
    [(or (= value -1) (<= width 0)) -1000000]
    [(and (= value -2) (= (array-ref gvn-ty-int ty) 1)) -2]
    [(and (>= value 0) (gvn-table-has-value? value ty)) value]
    [else -1000000]))

;; opt-load-cse-state-store
(define (gvn-step-store [ptr : i64] [ty : i64] [width : i64] [value : i64]) : unit
  (let
    [class : i64 0]
    [class-base : i64 0]
    [class-off : i64 0]
    [class-width : i64 0]
    [class-hdr : i64 0]
    [store-kind : i64 0]
    [store-id : i64 0]
    [store-epoch : i64 0]
    [forwarded : i64 -1000000]
    (begin
      (gvn-classify-store ptr width)
      (set! class gvn-k-tag)
      (set! class-base gvn-k-base)
      (set! class-off gvn-k-off)
      (set! class-width gvn-k-width)
      (set! class-hdr gvn-k-hdr)
      (gvn-root-of-value ptr)
      (set! store-kind gvn-root-kind)
      (set! store-id gvn-root-id)
      (set! store-epoch gvn-root-epoch)
      (when
        (not (= class 0))
        (set!
          forwarded
          (if (= width 8)
            (if (= value -1)
              -1000000
              value)
            (gvn-subword-forward value ty width))))
      (gvn-table-filter-store
        store-kind
        store-id
        store-epoch
        class
        class-base
        class-off
        class-width
        class-hdr)
      (when
        (and (not (= class 0)) (not (= forwarded -1000000)))
        (begin
          (gvn-key-for-address ptr -1 ty width)
          (gvn-table-bind forwarded gvn-epoch))))))

;; opt-load-cse-state-copy-bytes
(define (gvn-step-copy [dst : i64] [src : i64] [size : i64]) : unit
  (let
    [class : i64 0]
    [class-base : i64 0]
    [class-off : i64 0]
    [class-hdr : i64 0]
    [src-class : i64 0]
    [src-base : i64 0]
    [src-off : i64 0]
    [src-hdr : i64 0]
    [store-kind : i64 0]
    [store-id : i64 0]
    [store-epoch : i64 0]
    (begin
      (gvn-classify-store dst size)
      (set! class gvn-k-tag)
      (set! class-base gvn-k-base)
      (set! class-off gvn-k-off)
      (set! class-hdr gvn-k-hdr)
      (gvn-classify-store src size)
      (set! src-class gvn-k-tag)
      (set! src-base gvn-k-base)
      (set! src-off gvn-k-off)
      (set! src-hdr gvn-k-hdr)
      (gvn-root-of-value dst)
      (set! store-kind gvn-root-kind)
      (set! store-id gvn-root-id)
      (set! store-epoch gvn-root-epoch)
      (gvn-table-filter-store
        store-kind
        store-id
        store-epoch
        class
        class-base
        class-off
        size
        class-hdr)
      (when
        (and
          (= class 2)
          (= src-class 2)
          (= src-base class-base)
          (= src-hdr class-hdr)
          (gvn-ranges-disjoint? src-off size class-off size))
        (gvn-table-transfer-copy
          src-base
          src-off
          class-base
          class-off
          size
          class-hdr
          gvn-epoch)))))

;; opt-load-cse-core-load
(define (gvn-step-load
  [dst : i64]
  [src : i64]
  [ty : i64]
  [width : i64]
  [raw : i64]) : unit
  (let
    [earlier : i64 0]
    [record : bool false]
    (begin
      (when (>= dst 0) (gvn-table-invalidate-var dst))
      (gvn-key-for-address src raw ty width)
      (set! earlier (gvn-table-lookup))
      (if (not (= earlier -1000000))
        (begin
          (set! gvn-hits (+ gvn-hits 1))
          (gvn-alias-step gvn-op-mov dst earlier 0 width gvn-epoch)
          (gvn-kinds-step gvn-op-mov dst earlier ty width 0))
        (begin
          (set! gvn-misses (+ gvn-misses 1))
          (set! record (not (gvn-key-uses-var? dst)))
          (gvn-alias-step gvn-op-load dst src 0 width gvn-epoch)
          (when record (gvn-table-bind dst gvn-epoch))
          (gvn-kinds-step gvn-op-load dst src 0 width 0))))))

;; opt-load-cse-state-direct-call
(define (gvn-step-call [dst : i64] [is-alloc : i64] [effect : i64]) : unit
  (begin
    (unless (= effect 0) (gvn-table-clear))
    (when (= is-alloc 1) (set! gvn-epoch (+ gvn-epoch 1)))
    (gvn-alias-step gvn-op-call dst 0 is-alloc 0 gvn-epoch)
    (when (>= dst 0) (gvn-table-invalidate-var dst))
    (gvn-kinds-step gvn-op-call dst -1 0 0 0)))

;; opt-load-cse-dispatch
(define (gvn-dispatch
  [op : i64]
  [dst : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : unit
  (cond
    [(= op gvn-op-store) (gvn-step-store a b c d)]
    [(= op gvn-op-copy) (gvn-step-copy a b c)]
    [(= op gvn-op-load) (gvn-step-load dst a b c d)]
    [(= op gvn-op-call) (gvn-step-call dst b c)]
    [(= op gvn-op-clearall)
      (begin
        (gvn-table-clear)
        (gvn-alias-step op dst a b c gvn-epoch)
        (gvn-kinds-step op dst a b c d))]
    [else
      (begin
        (when (= op gvn-op-alloc) (set! gvn-epoch (+ gvn-epoch 1)))
        (gvn-alias-step op dst a b c gvn-epoch)
        (when (>= dst 0) (gvn-table-invalidate-var dst))
        (gvn-kinds-step op dst a b c d))]))

;; --- driver -----------------------------------------------------------------
(define (gvn-run-block [base : i64] [instrs : i64] [generation : i64]) : i64
  (let
    [hash : i64 0]
    [i : i64 0]
    [cursor : i64 base]
    (begin
      (set! gvn-table -1)
      (set! gvn-node-free -1)
      (set! gvn-node-bump 0)
      (set! gvn-epoch 0)
      (set! gvn-hits 0)
      (set! gvn-misses 0)
      (set! gvn-invalidations 0)
      (set! gvn-kinds-len 0)
      (set! gvn-kinds-gen generation)
      (set! gvn-table-cap (gvn-scaled-cap gvn-table-cap-floor instrs))
      (set! gvn-kinds-cap (gvn-scaled-cap gvn-kinds-cap-floor instrs))
      (gvn-facts-reset)
      (while (< i instrs)
        (begin
          (gvn-dispatch
            (array-ref gvn-tokens cursor)
            (array-ref gvn-tokens (+ cursor 1))
            (array-ref gvn-tokens (+ cursor 2))
            (array-ref gvn-tokens (+ cursor 3))
            (array-ref gvn-tokens (+ cursor 4))
            (array-ref gvn-tokens (+ cursor 5)))
          (set! cursor (+ cursor 6))
          (set! i (+ i 1))))
      (set! hash (gvn-mix gvn-hash-basis gvn-hits))
      (set! hash (gvn-mix hash gvn-misses))
      (set! hash (gvn-mix hash gvn-invalidations))
      (gvn-mix hash (gvn-table-len gvn-table)))))

(define (gvn-run-function [offset : i64]) : i64
  (let
    [vars : i64 (array-ref gvn-tokens offset)]
    [headers : i64 (array-ref gvn-tokens (+ offset 1))]
    [blocks : i64 (array-ref gvn-tokens (+ offset 2))]
    [cursor : i64 (+ offset 3)]
    [hash : i64 gvn-hash-basis]
    [i : i64 0]
    (begin
      (while (< i vars)
        (begin
          (array-set! gvn-header i 0)
          (array-set! gvn-kind-stamps i 0)
          (array-set! gvn-ref-stamps i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i headers)
        (begin
          (array-set! gvn-header (array-ref gvn-tokens cursor) 1)
          (set! cursor (+ cursor 1))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i blocks)
        (let
          [instrs : i64 (array-ref gvn-tokens cursor)]
          (begin
            (set!
              hash
              (gvn-mix hash (gvn-run-block (+ cursor 1) instrs (+ (* i 2) 1))))
            (set! cursor (+ cursor (+ 1 (* instrs 6))))
            (set! i (+ i 1)))))
      hash)))

(define (gvn-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (io.read-file path)]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [types : i64 0]
    [functions : i64 0]
    [cursor : i64 0]
    [max-vars : i64 1]
    [max-cap : i64 gvn-table-cap-floor]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 gvn-hash-basis]
    (begin
      (set! gvn-tokens (array.make-array i64 capacity))
      (set! acc (gvn-mix acc (gvn-scan-ints text gvn-tokens)))
      (set! types (array-ref gvn-tokens 0))
      (set! gvn-ty-width (array.make-array i64 (+ types 1)))
      (set! gvn-ty-int (array.make-array i64 (+ types 1)))
      (set! cursor 1)
      (let
        [t : i64 0]
        (while (< t types)
          (begin
            (array-set! gvn-ty-width t (array-ref gvn-tokens cursor))
            (array-set! gvn-ty-int t (array-ref gvn-tokens (+ cursor 1)))
            (set! cursor (+ cursor 2))
            (set! t (+ t 1)))))
      (set! functions (array-ref gvn-tokens cursor))
      (set! cursor (+ cursor 1))
      (set! gvn-offsets (array.make-array i64 (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [vars : i64 (array-ref gvn-tokens cursor)]
            [headers : i64 (array-ref gvn-tokens (+ cursor 1))]
            [blocks : i64 (array-ref gvn-tokens (+ cursor 2))]
            [scan : i64 (+ (+ cursor 3) headers)]
            [b : i64 0]
            (begin
              (array-set! gvn-offsets f cursor)
              (when (> vars max-vars) (set! max-vars vars))
              (while (< b blocks)
                (let
                  [instrs : i64 (array-ref gvn-tokens scan)]
                  [cap : i64 (gvn-scaled-cap gvn-table-cap-floor instrs)]
                  (begin
                    (when (> cap max-cap) (set! max-cap cap))
                    (set! scan (+ scan (+ 1 (* instrs 6))))
                    (set! b (+ b 1)))))
              (set! cursor scan)
              (set! f (+ f 1))))))
      (set! gvn-header (array.make-array i64 (+ max-vars 1)))
      (set! gvn-kinds (array.make-array i64 (+ max-vars 1)))
      (set! gvn-kind-stamps (array.make-array i64 (+ max-vars 1)))
      (set! gvn-kind-pos (array.make-array i64 (+ max-vars 1)))
      (set! gvn-refs (array.make-array i64 (+ max-vars 1)))
      (set! gvn-ref-stamps (array.make-array i64 (+ max-vars 1)))
      (set! gvn-active (array.make-array i64 (+ max-vars 1)))
      (let
        [fact-cap : i64 32]
        (begin
          (while (< fact-cap (* (+ max-vars 4) 8))
            (set! fact-cap (* fact-cap 2)))
          (set! gvn-fact-key (array.make-array i64 fact-cap))
          (set! gvn-fact-val (array.make-array i64 fact-cap))
          (set! gvn-fact-state (array.make-array i64 fact-cap))
          (set! gvn-fact-scratch-key (array.make-array i64 fact-cap))
          (set! gvn-fact-scratch-val (array.make-array i64 fact-cap))
          (set! gvn-fact-cap fact-cap)))
      (let
        [pool : i64 (+ (* max-cap 4) 128)]
        (begin
          (set! gvn-node-kind (array.make-array i64 pool))
          (set! gvn-node-a (array.make-array i64 pool))
          (set! gvn-node-b (array.make-array i64 pool))
          (set! gvn-node-ty (array.make-array i64 pool))
          (set! gvn-node-width (array.make-array i64 pool))
          (set! gvn-node-hdr (array.make-array i64 pool))
          (set! gvn-node-val (array.make-array i64 pool))
          (set! gvn-node-epoch (array.make-array i64 pool))
          (set! gvn-node-next (array.make-array i64 pool))))
      (set! gvn-copy-base (array.make-array i64 (+ max-cap 2)))
      (set! gvn-copy-off (array.make-array i64 (+ max-cap 2)))
      (set! gvn-copy-ty (array.make-array i64 (+ max-cap 2)))
      (set! gvn-copy-width (array.make-array i64 (+ max-cap 2)))
      (set! gvn-copy-val (array.make-array i64 (+ max-cap 2)))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          (begin
            (set! acc (gvn-mix acc round))
            (while (< step functions)
              (begin
                (set! index (+ start step))
                (when (>= index functions) (set! index (- index functions)))
                (set!
                  acc
                  (gvn-mix acc (gvn-run-function (array-ref gvn-offsets index))))
                (set! step (+ step 1))))
            (set! start (+ start 1))
            (when (>= start functions) (set! start 0))
            (set! round (+ round 1)))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (gvn-bench path rounds))
      0)))