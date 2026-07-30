;# benchmarks/peephole_lines/bench.tl - backend streaming peephole line scan.
;#
;# Equivalent to benchmarks/peephole_lines/baseline.c. The kernel is the
;# TypeLisp backend's assembly-text optimizer: the fallthrough-jump scan, the
;# streaming peephole that classifies every emitted line, applies the pair rule
;# set and the per-register reload-elision owner map while pushing line records,
;# and the dead-store sweep over those records. It runs over the compiler's own
;# emitted assembly -- a strided sample of the `.s` the snapshot compiler writes
;# for `src/main.tl` (see README.md).
;#
;# Mirrored compiler functions, all in src/compiler_backend.tl:
;#   compiler-backend-drop-fallthrough-jumps -- one forward pass, at most one
;#     deferred `    jmp SYM` candidate, excised only when nothing but label
;#     definitions separate it from a matching label
;#   compiler-backend-asm-direct-jmp-line? / -asm-label-def-line? /
;#     -asm-jmp-prefix-at? / -peephole-line-end / -peephole-ranges-eq?
;#   compiler-backend-peephole-asm-once-records-chunks -- the streaming walk
;#     with one pending descriptor, `prev-abort?`, and the owner map carried
;#     across chunk boundaries
;#   compiler-backend-peephole-parse-line -- the transient line descriptor:
;#     mnemonic token, the ten line predicates, the movq/zext operand split,
;#     owner keys, operand flags and register indices
;#   compiler-backend-peephole-movq-prefix-at-range?, -mnemonic-zext?,
;#     -mnemonic-call?, -mnemonic-single-dest?, -cmp-or-test-token?,
;#     -line-noreturn-abort?, -token-len, -register-range?,
;#     -memory-base-range, -owner-key-from-range,
;#     -stack-owner-key-from-parts, -operand-flags, -reg-index-range,
;#     -last-operand-reg-index
;#   compiler-backend-peephole-pair-action-desc -- the five rule outcomes:
;#     0 emit pending, 1 replace pending, 2 drop next, 3 forward frame load,
;#     4 r10 base fold; plus -redundant-zext-pair-desc? and
;#     -line-self-move-desc?
;#   compiler-backend-peephole-emit-line-desc-record -- reload elision, the
;#     cross-register reuse rewrite, and the record push
;#   compiler-backend-peephole-movq-owners-transfer-keyed-index,
;#     -owners-clear-slot, -owners-clear-call-clobbers,
;#     -line-clobber-owners-desc, -owners-get-index, -owners-set-reg-index,
;#     -owners-find-reg-for-slot-index
;#   compiler-backend-deadstore-sweep-records! /
;#     compiler-backend-sweep-region-records! -- the two-pass region sweep
;#
;# KEPT: the line classification, the whole pair rule set with its pending-line
;# state machine, the 14-register owner map with its store/load/clobber/call
;# transfers, the record array with its `live` deletion mask, and the two-pass
;# dead-store sweep with its rsp-delta replay, address-taken watermark and
;# read-range overlap test.
;#
;# DROPPED, and why: (1) rewritten line TEXT is never materialized -- an action
;# 3/4 or reload rewrite produces `    movq SRC, DST` from two operand spans
;# that already exist in the corpus, so the record keeps the two spans instead
;# of the `str-cat` result; the rules only ever re-read those operands, and the
;# checksum counts lines rather than bytes. (2) `SYM(%rip)` global owner keys
;# are dropped (they need the backend's live intern table, which the peephole
;# runs after tearing down); stack-slot keys, which drive every reload rule,
;# are kept exactly. (3) The carry-safe label set and the r10-dead forward scan
;# depend on per-function backend state that is not in the assembly text, so a
;# label always resets the owner map and rule 4 requires its own `%r10`
;# destination. (4) The sweep's frame window comes from the register allocator;
;# here the whole function chunk is the region, which is what the sweep degrades
;# to when the recorded window covers the frame.
;#
;# Each `.globl` line starts a new chunk, which is exactly where the compiler
;# resets pending-pair and owner state. The corpus path and the round count are
;# runtime arguments; each round rotates the starting chunk by one, so nothing
;# can be constant folded and no round repeats an earlier accumulator. The
;# checksum is a wrapping 64-bit FNV-1a fold with no division, so the printed
;# decimal matches the C baseline's `%lld` bit for bit.
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define pl-hash-basis : i64
  1469598103934665603)
(define pl-hash-prime : i64
  1099511628211)

;; compiler-backend-peephole-owner-key-stack-bias
(define pl-owner-key-bias : i64
  1073741824)

;; compiler-backend-peephole-op-*-flag
(define pl-op-register : i64
  1)
(define pl-op-stack : i64
  2)
(define pl-op-local-frame : i64
  4)
(define pl-op-r10-base : i64
  8)

;; Line descriptor fields (CompilerBackendPeepholeLine).
(define pl-f-start : i64
  0)
(define pl-f-end : i64
  1)
(define pl-f-newline : i64
  2)
(define pl-f-owned : i64
  3)
(define pl-f-mn-start : i64
  4)
(define pl-f-mn-len : i64
  5)
(define pl-f-movq : i64
  6)
(define pl-f-label : i64
  7)
(define pl-f-abort : i64
  8)
(define pl-f-clears : i64
  9)
(define pl-f-call : i64
  10)
(define pl-f-single : i64
  11)
(define pl-f-zext : i64
  12)
(define pl-f-hasops : i64
  13)
(define pl-f-src-start : i64
  14)
(define pl-f-src-end : i64
  15)
(define pl-f-dst-start : i64
  16)
(define pl-f-dst-end : i64
  17)
(define pl-f-src-key : i64
  18)
(define pl-f-dst-key : i64
  19)
(define pl-f-src-flags : i64
  20)
(define pl-f-dst-flags : i64
  21)
(define pl-f-src-reg : i64
  22)
(define pl-f-dst-reg : i64
  23)
(define pl-f-last-reg : i64
  24)
(define pl-f-count : i64
  25)

;; Sweep record flags.
(define pl-sw-label : i64
  1)
(define pl-sw-leaq : i64
  2)
(define pl-sw-push : i64
  4)
(define pl-sw-pop : i64
  8)
(define pl-sw-rsp-dst : i64
  16)
(define pl-sw-tracked : i64
  32)
(define pl-sw-subq : i64
  64)
(define pl-sw-fatal : i64
  128)
(define pl-none : i64
  4611686018427387904)
(define pl-text : String
  "")
(define pl-len : i64
  0)
(define pl-chunk-start : (Array i64)
  (array.make-array i64 1))
(define pl-chunk-end : (Array i64)
  (array.make-array i64 1))
(define pl-chunk-count : i64
  0)
(define pl-pending : (Array i64)
  (array.make-array i64 25))
(define pl-next : (Array i64)
  (array.make-array i64 25))

;; Line records (CompilerBackendPeepholeLineVec).
(define pl-rec-owned : (Array i64)
  (array.make-array i64 1))
(define pl-rec-src-start : (Array i64)
  (array.make-array i64 1))
(define pl-rec-src-end : (Array i64)
  (array.make-array i64 1))
(define pl-rec-dst-start : (Array i64)
  (array.make-array i64 1))
(define pl-rec-dst-end : (Array i64)
  (array.make-array i64 1))
(define pl-rec-flags : (Array i64)
  (array.make-array i64 1))
(define pl-rec-cand : (Array i64)
  (array.make-array i64 1))
(define pl-rec-read : (Array i64)
  (array.make-array i64 1))
(define pl-rec-width : (Array i64)
  (array.make-array i64 1))
(define pl-rec-value : (Array i64)
  (array.make-array i64 1))
(define pl-rec-live : (Array i64)
  (array.make-array i64 1))
(define pl-rec-len : i64
  0)

;; Sweep scratch.
(define pl-sweep-cand-pos : (Array i64)
  (array.make-array i64 1))
(define pl-sweep-cand-off : (Array i64)
  (array.make-array i64 1))
(define pl-sweep-read-lo : (Array i64)
  (array.make-array i64 1))
(define pl-sweep-read-hi : (Array i64)
  (array.make-array i64 1))

;; Per-register owner map (CompilerBackendPeepholeOwners), 14 tracked GP
;; registers in reg-index order.
(define pl-owners : (Array i64)
  (array.make-array i64 14))

;; Counters folded into the checksum.
(define pl-kept : i64
  0)
(define pl-dropped : i64
  0)
(define pl-rule1 : i64
  0)
(define pl-rule2 : i64
  0)
(define pl-rule3 : i64
  0)
(define pl-rule4 : i64
  0)
(define pl-elided : i64
  0)
(define pl-reused : i64
  0)
(define pl-fallthrough : i64
  0)
(define pl-swept : i64
  0)

(define (pl-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) pl-hash-prime))

;; compiler-backend-peephole-byte-at
(define (pl-byte-at [i : i64]) : i64
  (if (and (>= i 0) (< i pl-len))
    (cast (string.string-ref pl-text i) : i64)
    -1))

;; compiler-backend-peephole-line-end
(define (pl-line-end [i : i64] [n : i64]) : i64
  (let
    [scan : i64 i]
    (begin
      (while (and (< scan n) (not (= (pl-byte-at scan) 10)))
        (set! scan (+ scan 1)))
      scan)))

;; compiler-backend-peephole-ranges-eq?
(define (pl-ranges-eq?
  [a-start : i64]
  [a-end : i64]
  [b-start : i64]
  [b-end : i64]) : bool
  (if (not (= (- a-end a-start) (- b-end b-start)))
    false
    (let
      [i : i64 0]
      [n : i64 (- a-end a-start)]
      [same : bool true]
      (begin
        (while (and same (< i n))
          (begin
            (when
              (not (= (pl-byte-at (+ a-start i)) (pl-byte-at (+ b-start i))))
              (set! same false))
            (set! i (+ i 1))))
        same))))

;; compiler-backend-peephole-token-len
(define (pl-token-len [i : i64] [end : i64]) : i64
  (let
    [scan : i64 i]
    (begin
      (while (and (< scan end) (not (= (pl-byte-at scan) 32)))
        (set! scan (+ scan 1)))
      (- scan i))))

;; compiler-backend-peephole-find-comma-space-range
(define (pl-find-comma-space [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< (+ i 1) end))
        (begin
          (when
            (and (= (pl-byte-at i) 44) (= (pl-byte-at (+ i 1)) 32))
            (set! found i))
          (set! i (+ i 1))))
      found)))

;; compiler-backend-peephole-movq-prefix-at-range?
(define (pl-movq-prefix? [start : i64] [end : i64]) : bool
  (and
    (<= (+ start 9) end)
    (= (pl-byte-at start) 32)
    (= (pl-byte-at (+ start 1)) 32)
    (= (pl-byte-at (+ start 2)) 32)
    (= (pl-byte-at (+ start 3)) 32)
    (= (pl-byte-at (+ start 4)) 109)
    (= (pl-byte-at (+ start 5)) 111)
    (= (pl-byte-at (+ start 6)) 118)
    (= (pl-byte-at (+ start 7)) 113)
    (= (pl-byte-at (+ start 8)) 32)))

;; compiler-backend-peephole-mnemonic-zext?
(define (pl-mnemonic-zext? [i : i64] [mlen : i64]) : bool
  (and
    (= mlen 6)
    (= (pl-byte-at i) 109)
    (= (pl-byte-at (+ i 1)) 111)
    (= (pl-byte-at (+ i 2)) 118)
    (= (pl-byte-at (+ i 3)) 122)
    (= (pl-byte-at (+ i 4)) 98)
    (or (= (pl-byte-at (+ i 5)) 113) (= (pl-byte-at (+ i 5)) 108))))

;; compiler-backend-peephole-mnemonic-call?
(define (pl-mnemonic-call? [i : i64] [mlen : i64]) : bool
  (and
    (or (= mlen 4) (= mlen 5))
    (= (pl-byte-at i) 99)
    (= (pl-byte-at (+ i 1)) 97)
    (= (pl-byte-at (+ i 2)) 108)
    (= (pl-byte-at (+ i 3)) 108)
    (or (= mlen 4) (= (pl-byte-at (+ i 4)) 113))))

;; compiler-backend-peephole-cmp-or-test-token?: cmp/test with an optional
;; q/l/w/b width suffix write only the flags.
(define (pl-cmp-or-test? [i : i64] [mlen : i64]) : bool
  (let
    [suffix : i64 (pl-byte-at (+ i (- mlen 1)))]
    [suffixed? : bool
      (or (= suffix 113) (= suffix 108) (= suffix 119) (= suffix 98))]
    (or
      (and
        (or (= mlen 3) (and (= mlen 4) suffixed?))
        (= (pl-byte-at i) 99)
        (= (pl-byte-at (+ i 1)) 109)
        (= (pl-byte-at (+ i 2)) 112))
      (and
        (or (= mlen 4) (and (= mlen 5) suffixed?))
        (= (pl-byte-at i) 116)
        (= (pl-byte-at (+ i 1)) 101)
        (= (pl-byte-at (+ i 2)) 115)
        (= (pl-byte-at (+ i 3)) 116)))))

;; compiler-backend-peephole-mnemonic-single-dest?: setcc, movabsq, the
;; movz/movs widening moves, and the three-byte-keyed q/l/w/b ops that write one
;; general-purpose destination.
(define (pl-single-dest? [i : i64] [mlen : i64]) : bool
  (if (< mlen 3)
    false
    (let
      [b0 : i64 (pl-byte-at i)]
      [b1 : i64 (pl-byte-at (+ i 1))]
      [b2 : i64 (pl-byte-at (+ i 2))]
      [base3 : i64 (+ b0 (+ (* b1 256) (* b2 65536)))]
      [suffix : i64 (pl-byte-at (+ i (- mlen 1)))]
      (cond
        [(and (= b0 115) (= b1 101) (= b2 116)) true]
        [(= mlen 7)
          (and
            (= base3 7761773)
            (= (pl-byte-at (+ i 3)) 97)
            (= (pl-byte-at (+ i 4)) 98)
            (= (pl-byte-at (+ i 5)) 115)
            (= (pl-byte-at (+ i 6)) 113))]
        [(= mlen 6)
          (let
            [kind : i64 (pl-byte-at (+ i 3))]
            [width : i64 (pl-byte-at (+ i 4))]
            (and
              (= base3 7761773)
              (= (pl-byte-at (+ i 5)) 113)
              (or
                (and (= kind 122) (or (= width 98) (= width 119)))
                (and (= kind 115) (or (= width 98) (= width 119) (= width 108))))))]
        [else
          (and
            (or (= suffix 113) (= suffix 108) (= suffix 119) (= suffix 98))
            (or
              (and (= mlen 3) (= b0 111) (= b1 114))
              (and
                (= mlen 4)
                (or
                  (and (not (= suffix 113)) (= base3 7761773))
                  (= base3 6579297)
                  (= base3 6452595)
                  (= base3 6581857)
                  (= base3 7499640)
                  (= base3 7104627)
                  (= base3 7497843)
                  (= base3 7496051)
                  (= base3 7102835)
                  (= base3 6776174)
                  (= base3 7630702)
                  (= base3 6516329)
                  (= base3 6514020)
                  (= base3 6382956)))))]))))

;; compiler-backend-peephole-reg-index-range: the 14 owner-tracked registers.
(define (pl-reg-index [start : i64] [end : i64]) : i64
  (let
    [n : i64 (- end start)]
    (if (or (< n 3) (> n 4))
      -1
      (let
        [b0 : i64 (pl-byte-at start)]
        [b1 : i64 (pl-byte-at (+ start 1))]
        [b2 : i64 (pl-byte-at (+ start 2))]
        (if (or (not (= b0 37)) (not (= b1 114)))
          -1
          (if (= n 3)
            (cond [(= b2 56) 6] [(= b2 57) 7] [else -1])
            (let
              [b3 : i64 (pl-byte-at (+ start 3))]
              (cond
                [(= b2 97)
                  (if (= b3 120)
                    0
                    -1)]
                [(= b2 99)
                  (if (= b3 120)
                    1
                    -1)]
                [(= b2 100) (cond [(= b3 120) 2] [(= b3 105) 5] [else -1])]
                [(= b2 98)
                  (if (= b3 120)
                    3
                    -1)]
                [(= b2 115)
                  (if (= b3 105)
                    4
                    -1)]
                [(= b2 49)
                  (cond
                    [(= b3 48) 8]
                    [(= b3 49) 9]
                    [(= b3 50) 10]
                    [(= b3 51) 11]
                    [(= b3 52) 12]
                    [(= b3 53) 13]
                    [else -1])]
                [else -1]))))))))

;; compiler-backend-peephole-last-operand-reg-index: the register token after
;; the final ", " on the line.
(define (pl-last-operand-reg [start : i64] [end : i64]) : i64
  (let
    [cut : i64 -1]
    [i : i64 start]
    (begin
      (while (< (+ i 1) end)
        (begin
          (when
            (and (= (pl-byte-at i) 44) (= (pl-byte-at (+ i 1)) 32))
            (set! cut i))
          (set! i (+ i 1))))
      (if (< cut 0)
        -1
        (pl-reg-index (+ cut 2) end)))))

;; compiler-backend-peephole-memory-base-range: 0 none, 1 rbp, 2 rsp, 3 rip,
;; 4 r10 -- the six-byte suffix the backend emits for a fixed base.
(define (pl-memory-base [start : i64] [end : i64]) : i64
  (if (< (- end start) 6)
    0
    (let
      [s : i64 (- end 6)]
      (if (and
        (= (pl-byte-at s) 40)
        (= (pl-byte-at (+ s 1)) 37)
        (= (pl-byte-at (+ s 2)) 114)
        (= (pl-byte-at (+ s 5)) 41))
        (let
          [b3 : i64 (pl-byte-at (+ s 3))]
          [b4 : i64 (pl-byte-at (+ s 4))]
          (if (= b4 112)
            (cond [(= b3 98) 1] [(= b3 115) 2] [(= b3 105) 3] [else 0])
            (if (and (= b3 49) (= b4 48))
              4
              0)))
        0))))

;; compiler-backend-peephole-decimal-range-valid? / -decimal-range-value
(define (pl-decimal-valid? [start : i64] [end : i64]) : bool
  (if (>= start end)
    false
    (let
      [i : i64
        (if (= (pl-byte-at start) 45)
          (+ start 1)
          start)]
      [ok : bool true]
      (begin
        (when (>= i end) (set! ok false))
        (while (and ok (< i end))
          (let
            [b : i64 (pl-byte-at i)]
            (begin
              (when (or (< b 48) (> b 57)) (set! ok false))
              (set! i (+ i 1)))))
        ok))))

(define (pl-decimal-value [start : i64] [end : i64]) : i64
  (let
    [negative : bool (= (pl-byte-at start) 45)]
    [i : i64
      (if (= (pl-byte-at start) 45)
        (+ start 1)
        start)]
    [value : i64 0]
    (begin
      (while (< i end)
        (begin
          (set! value (+ (* value 10) (- (pl-byte-at i) 48)))
          (set! i (+ i 1))))
      (if negative
        (- 0 value)
        value))))

;; compiler-backend-peephole-stack-owner-key-from-parts
(define (pl-stack-owner-key [base : i64] [offset : i64] [explicit : bool]) : i64
  (if (or (< offset (- 0 pl-owner-key-bias)) (> offset pl-owner-key-bias))
    0
    (+
      1
      (+
        (* 4 (+ offset pl-owner-key-bias))
        (+
          (* base 2)
          (if explicit
            1
            0))))))

;; compiler-backend-peephole-owner-key-from-range, without the `SYM(%rip)`
;; global keys (see the header's dropped list).
(define (pl-owner-key [start : i64] [end : i64] [memory-base : i64]) : i64
  (let
    [prefix-end : i64 (- end 6)]
    (if (or (= memory-base 1) (= memory-base 2))
      (let
        [base : i64
          (if (= memory-base 1)
            0
            1)]
        (cond
          [(= prefix-end start) (pl-stack-owner-key base 0 false)]
          [(pl-decimal-valid? start prefix-end)
            (pl-stack-owner-key base (pl-decimal-value start prefix-end) true)]
          [else 0]))
      0)))

;; compiler-backend-peephole-stack-parens-range: bit 1 = "(%rbp)", bit 2 =
;; "(%rsp)" anywhere in the operand.
(define (pl-stack-parens [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [bits : i64 0]
    (begin
      (while (<= (+ i 6) end)
        (begin
          (when
            (and
              (= (pl-byte-at i) 40)
              (= (pl-byte-at (+ i 1)) 37)
              (= (pl-byte-at (+ i 2)) 114)
              (= (pl-byte-at (+ i 4)) 112)
              (= (pl-byte-at (+ i 5)) 41))
            (let
              [b3 : i64 (pl-byte-at (+ i 3))]
              (cond
                [(= b3 98) (set! bits (bit-or bits 1))]
                [(= b3 115) (set! bits (bit-or bits 2))]
                [else unit])))
          (set! i (+ i 1))))
      bits)))

;; compiler-backend-peephole-operand-flags
(define (pl-operand-flags
  [start : i64]
  [end : i64]
  [key : i64]
  [memory-base : i64]) : i64
  (let
    [register? : bool (and (< start end) (= (pl-byte-at start) 37))]
    [packed-stack? : bool (> key 0)]
    [base-rbp? : bool (= memory-base 1)]
    [base-rsp? : bool (= memory-base 2)]
    [leading-minus? : bool (and (< start end) (= (pl-byte-at start) 45))]
    [parens : i64
      (if (and
        (not packed-stack?)
        (or base-rbp? (and (not base-rsp?) (>= (- end start) 6))))
        (pl-stack-parens start end)
        0)]
    [stack? : bool (or packed-stack? base-rbp? base-rsp? (not (= parens 0)))]
    [local-frame? : bool
      (if packed-stack?
        (or (not (= (bit-and (- key 1) 2) 0)) leading-minus?)
        (cond
          [base-rsp? true]
          [base-rbp? (or leading-minus? (not (= (bit-and parens 2) 0)))]
          [else
            (and
              stack?
              (or
                (not (= (bit-and parens 2) 0))
                (and leading-minus? (not (= (bit-and parens 1) 0)))))]))]
    [r10-base? : bool (= memory-base 4)]
    (+
      (if register?
        pl-op-register
        0)
      (+
        (if stack?
          pl-op-stack
          0)
        (+
          (if local-frame?
            pl-op-local-frame
            0)
          (if r10-base?
            pl-op-r10-base
            0))))))

;; compiler-backend-peephole-line-noreturn-abort?
(define (pl-noreturn-abort? [start : i64] [end : i64]) : bool
  (let
    [i : i64 start]
    [e : i64 end]
    (begin
      (while (and (< i end) (= (pl-byte-at i) 32))
        (set! i (+ i 1)))
      (while (and (> e i) (= (pl-byte-at (- e 1)) 32))
        (set! e (- e 1)))
      (and
        (> (- e i) 5)
        (= (pl-byte-at i) 99)
        (= (pl-byte-at (+ i 1)) 97)
        (= (pl-byte-at (+ i 2)) 108)
        (= (pl-byte-at (+ i 3)) 108)
        (= (pl-byte-at (+ i 4)) 32)
        (= (pl-byte-at (+ i 5)) 116)
        (= (pl-byte-at (+ i 6)) 108)
        (= (pl-byte-at (+ i 7)) 95)
        (pl-suffix-abort? (+ i 8) e)))))

(define (pl-suffix-abort? [start : i64] [end : i64]) : bool
  (and
    (>= (- end start) 5)
    (= (pl-byte-at (- end 5)) 97)
    (= (pl-byte-at (- end 4)) 98)
    (= (pl-byte-at (- end 3)) 111)
    (= (pl-byte-at (- end 2)) 114)
    (= (pl-byte-at (- end 1)) 116)))

;; compiler-backend-peephole-parse-line
(define (pl-parse-line
  [slot : (Array i64)]
  [start : i64]
  [end : i64]
  [newline : bool]) : unit
  (let
    [ms : i64 start]
    (begin
      (while (and (< ms end) (= (pl-byte-at ms) 32))
        (set! ms (+ ms 1)))
      (let
        [mlen : i64 (pl-token-len ms end)]
        [operand-start : i64 (+ ms mlen)]
        [has-operands : bool false]
        [comma : i64 -1]
        [movq-prefix? : bool (pl-movq-prefix? start end)]
        [zext? : bool (pl-mnemonic-zext? ms mlen)]
        (begin
          (when
            (or movq-prefix? zext?)
            (begin
              (while (and
                (< operand-start end)
                (= (pl-byte-at operand-start) 32))
                (set! operand-start (+ operand-start 1)))
              (set! comma (pl-find-comma-space operand-start end))
              (when
                (and (> comma operand-start) (< (+ comma 2) end))
                (set! has-operands true))))
          (let
            [is-movq : bool (and has-operands movq-prefix?)]
            [src-start : i64 operand-start]
            [src-end : i64
              (if has-operands
                comma
                operand-start)]
            [dst-start : i64
              (if has-operands
                (+ comma 2)
                end)]
            [is-label : bool (and (< ms end) (= (pl-byte-at (- end 1)) 58))]
            [cmp? : bool (pl-cmp-or-test? ms mlen)]
            [clears : bool
              (cond
                [(>= ms end) false]
                [is-label true]
                [(= (pl-byte-at ms) 46) false]
                [(= (pl-byte-at ms) 106) false]
                [cmp? false]
                [else true])]
            [call? : bool (pl-mnemonic-call? ms mlen)]
            [single? : bool
              (and
                (not is-movq)
                (not is-label)
                clears
                (not call?)
                (pl-single-dest? ms mlen))]
            [last-reg : i64
              (if (or single? zext?)
                (pl-last-operand-reg start end)
                -1)]
            [src-base : i64
              (if is-movq
                (pl-memory-base src-start src-end)
                0)]
            [dst-base : i64
              (if is-movq
                (pl-memory-base dst-start end)
                0)]
            [src-key : i64
              (if is-movq
                (pl-owner-key src-start src-end src-base)
                0)]
            [dst-key : i64
              (if is-movq
                (pl-owner-key dst-start end dst-base)
                0)]
            (begin
              (array-set! slot pl-f-start start)
              (array-set! slot pl-f-end end)
              (array-set!
                slot
                pl-f-newline
                (if newline
                  1
                  0))
              (array-set! slot pl-f-owned 0)
              (array-set! slot pl-f-mn-start ms)
              (array-set! slot pl-f-mn-len mlen)
              (array-set!
                slot
                pl-f-movq
                (if is-movq
                  1
                  0))
              (array-set!
                slot
                pl-f-label
                (if is-label
                  1
                  0))
              (array-set!
                slot
                pl-f-abort
                (if (and call? (pl-noreturn-abort? start end))
                  1
                  0))
              (array-set!
                slot
                pl-f-clears
                (if clears
                  1
                  0))
              (array-set!
                slot
                pl-f-call
                (if call?
                  1
                  0))
              (array-set!
                slot
                pl-f-single
                (if single?
                  1
                  0))
              (array-set!
                slot
                pl-f-zext
                (if zext?
                  1
                  0))
              (array-set!
                slot
                pl-f-hasops
                (if has-operands
                  1
                  0))
              (array-set! slot pl-f-src-start src-start)
              (array-set! slot pl-f-src-end src-end)
              (array-set! slot pl-f-dst-start dst-start)
              (array-set! slot pl-f-dst-end end)
              (array-set! slot pl-f-src-key src-key)
              (array-set! slot pl-f-dst-key dst-key)
              (array-set!
                slot
                pl-f-src-flags
                (if is-movq
                  (pl-operand-flags src-start src-end src-key src-base)
                  0))
              (array-set!
                slot
                pl-f-dst-flags
                (if is-movq
                  (pl-operand-flags dst-start end dst-key dst-base)
                  0))
              (array-set!
                slot
                pl-f-src-reg
                (if is-movq
                  (pl-reg-index src-start src-end)
                  -1))
              (array-set!
                slot
                pl-f-dst-reg
                (if is-movq
                  (pl-reg-index dst-start end)
                  -1))
              (array-set! slot pl-f-last-reg last-reg))))))))

;; compiler-backend-peephole-owned-line for the synthesized `    movq SRC, DST`
;; that rules 3 and 4 and the cross-register reload rewrite build. The two
;; operand spans already exist in the corpus, so the descriptor is derived
;; directly instead of formatting and re-parsing the text.
(define (pl-owned-line
  [slot : (Array i64)]
  [src-start : i64]
  [src-end : i64]
  [dst-start : i64]
  [dst-end : i64]
  [newline : i64]) : unit
  (let
    [src-base : i64 (pl-memory-base src-start src-end)]
    [dst-base : i64 (pl-memory-base dst-start dst-end)]
    [src-key : i64 (pl-owner-key src-start src-end src-base)]
    [dst-key : i64 (pl-owner-key dst-start dst-end dst-base)]
    (begin
      (array-set! slot pl-f-start -1)
      (array-set! slot pl-f-end -1)
      (array-set! slot pl-f-newline newline)
      (array-set! slot pl-f-owned 1)
      (array-set! slot pl-f-mn-start -1)
      (array-set! slot pl-f-mn-len 4)
      (array-set! slot pl-f-movq 1)
      (array-set! slot pl-f-label 0)
      (array-set! slot pl-f-abort 0)
      (array-set! slot pl-f-clears 1)
      (array-set! slot pl-f-call 0)
      (array-set! slot pl-f-single 0)
      (array-set! slot pl-f-zext 0)
      (array-set! slot pl-f-hasops 1)
      (array-set! slot pl-f-src-start src-start)
      (array-set! slot pl-f-src-end src-end)
      (array-set! slot pl-f-dst-start dst-start)
      (array-set! slot pl-f-dst-end dst-end)
      (array-set! slot pl-f-src-key src-key)
      (array-set! slot pl-f-dst-key dst-key)
      (array-set!
        slot
        pl-f-src-flags
        (pl-operand-flags src-start src-end src-key src-base))
      (array-set!
        slot
        pl-f-dst-flags
        (pl-operand-flags dst-start dst-end dst-key dst-base))
      (array-set! slot pl-f-src-reg (pl-reg-index src-start src-end))
      (array-set! slot pl-f-dst-reg (pl-reg-index dst-start dst-end))
      (array-set! slot pl-f-last-reg -1))))

;; compiler-backend-peephole-line-copy
(define (pl-copy-line [dst : (Array i64)] [src : (Array i64)]) : unit
  (let
    [i : i64 0]
    (while (< i pl-f-count)
      (begin
        (array-set! dst i (array-ref src i))
        (set! i (+ i 1))))))

;; compiler-backend-peephole-line-self-move-desc?
(define (pl-self-move? [slot : (Array i64)]) : bool
  (and
    (= (array-ref slot pl-f-movq) 1)
    (not (= (bit-and (array-ref slot pl-f-src-flags) 3) 0))
    (pl-ranges-eq?
      (array-ref slot pl-f-src-start)
      (array-ref slot pl-f-src-end)
      (array-ref slot pl-f-dst-start)
      (array-ref slot pl-f-dst-end))))

;; compiler-backend-peephole-redundant-zext-pair-desc?
(define (pl-redundant-zext? [pending : (Array i64)] [next : (Array i64)]) : bool
  (if (= (array-ref pending pl-f-zext) 0)
    false
    (let
      [reg : i64 (array-ref pending pl-f-last-reg)]
      (if (< reg 0)
        false
        (if (or
          (= (array-ref next pl-f-hasops) 0)
          (not (= (array-ref next pl-f-mn-len) 6))
          (not (pl-mnemonic-zext? (array-ref next pl-f-mn-start) 6))
          (not (= (pl-byte-at (+ (array-ref next pl-f-mn-start) 5)) 113)))
          false
          (let
            [src-start : i64 (array-ref next pl-f-src-start)]
            [src-end : i64 (array-ref next pl-f-src-end)]
            (if (or (= src-start src-end) (not (= (pl-byte-at src-start) 37)))
              false
              (let
                [last : i64 (pl-byte-at (- src-end 1))]
                (if (not (or (= last 108) (= last 98)))
                  false
                  (and
                    (= (pl-reg-index src-start src-end) reg)
                    (= (array-ref next pl-f-last-reg) reg)))))))))))

;; compiler-backend-peephole-pair-action-desc
(define (pl-pair-action [pending : (Array i64)] [next : (Array i64)]) : i64
  (cond
    [(pl-redundant-zext? pending next) 2]
    [(= (array-ref pending pl-f-movq) 0) 0]
    [(pl-self-move? pending) 1]
    [(= (array-ref next pl-f-movq) 0) 0]
    [else
      (let
        [pss : i64 (array-ref pending pl-f-src-start)]
        [pse : i64 (array-ref pending pl-f-src-end)]
        [pds : i64 (array-ref pending pl-f-dst-start)]
        [pde : i64 (array-ref pending pl-f-dst-end)]
        [nss : i64 (array-ref next pl-f-src-start)]
        [nse : i64 (array-ref next pl-f-src-end)]
        [nds : i64 (array-ref next pl-f-dst-start)]
        [nde : i64 (array-ref next pl-f-dst-end)]
        [psf : i64 (array-ref pending pl-f-src-flags)]
        [pdf : i64 (array-ref pending pl-f-dst-flags)]
        [nsf : i64 (array-ref next pl-f-src-flags)]
        [ndf : i64 (array-ref next pl-f-dst-flags)]
        (cond
          [(and
              (not (= (bit-and psf pl-op-register) 0))
              (not (= (bit-and pdf pl-op-local-frame) 0))
              (not (= (bit-and nsf pl-op-register) 0))
              (not (= (bit-and ndf pl-op-local-frame) 0))
              (pl-ranges-eq? pds pde nds nde))
            1]
          [(and
              (not (= (bit-and psf 3) 0))
              (not (= (bit-and pdf 3) 0))
              (not (= (bit-and nsf 3) 0))
              (not (= (bit-and ndf 3) 0))
              (or
                (and
                  (pl-ranges-eq? pss pse nss nse)
                  (pl-ranges-eq? pds pde nds nde))
                (and
                  (pl-ranges-eq? pds pde nss nse)
                  (pl-ranges-eq? pss pse nds nde))))
            2]
          [(and
              (not (= (bit-and psf pl-op-register) 0))
              (not (= (bit-and pdf pl-op-local-frame) 0))
              (not (= (bit-and nsf pl-op-local-frame) 0))
              (not (= (bit-and ndf pl-op-register) 0))
              (pl-ranges-eq? pds pde nss nse))
            3]
          [(and
              (not (= (bit-and psf pl-op-register) 0))
              (not (= (pl-reg-index pss pse) 8))
              (= (array-ref pending pl-f-dst-reg) 8)
              (not (= (bit-and nsf pl-op-r10-base) 0))
              (not (= (bit-and ndf pl-op-register) 0))
              (= (array-ref next pl-f-dst-reg) 8))
            4]
          [else 0]))]))

;; compiler-backend-peephole-owners-clear-slot
(define (pl-owners-clear-slot [slot : i64]) : unit
  (let
    [i : i64 0]
    (while (< i 14)
      (begin
        (when (= (array-ref pl-owners i) slot) (array-set! pl-owners i 0))
        (set! i (+ i 1))))))

;; compiler-backend-peephole-owners-find-reg-for-slot-index
(define (pl-owners-find-reg [slot : i64] [exclude : i64]) : i64
  (if (= slot 0)
    -1
    (let
      [i : i64 0]
      [found : i64 -1]
      (begin
        (while (and (< found 0) (< i 14))
          (begin
            (when
              (and (not (= i exclude)) (= (array-ref pl-owners i) slot))
              (set! found i))
            (set! i (+ i 1))))
        found))))

;; compiler-backend-peephole-owners-clear-call-clobbers: only %rbx, %r12..%r15
;; keep a stack-slot owner across a call.
(define (pl-owners-clear-call) : unit
  (let
    [i : i64 0]
    (while (< i 14)
      (begin
        (if (or (= i 3) (>= i 10))
          (when (not (> (array-ref pl-owners i) 0)) (array-set! pl-owners i 0))
          (array-set! pl-owners i 0))
        (set! i (+ i 1))))))

(define (pl-owners-empty) : unit
  (let
    [i : i64 0]
    (while (< i 14)
      (begin
        (array-set! pl-owners i 0)
        (set! i (+ i 1))))))

;; compiler-backend-peephole-movq-owners-transfer-keyed-index
(define (pl-owners-transfer
  [src-reg : i64]
  [dst-reg : i64]
  [src-key : i64]
  [dst-key : i64]) : unit
  (cond
    [(> dst-key 0)
      (begin
        (pl-owners-clear-slot dst-key)
        (when
          (and (>= src-reg 0) (= (array-ref pl-owners src-reg) 0))
          (array-set! pl-owners src-reg dst-key)))]
    [(>= dst-reg 0) (array-set! pl-owners dst-reg src-key)]
    [else (pl-owners-empty)]))

;; compiler-backend-peephole-line-clobber-owners-desc
;; `_prev-abort` is the compiler's guard-ok-label refinement, which needs the
;; backend's carry-safe label set; see the header's dropped list.
(define (pl-clobber-owners [slot : (Array i64)] [_prev-abort : i64]) : unit
  (cond
    [(= (array-ref slot pl-f-abort) 1) unit]
    [(= (array-ref slot pl-f-label) 1) (pl-owners-empty)]
    [(= (array-ref slot pl-f-clears) 0) unit]
    [(= (array-ref slot pl-f-call) 1) (pl-owners-clear-call)]
    [(= (array-ref slot pl-f-single) 1)
      (let
        [dreg : i64 (array-ref slot pl-f-last-reg)]
        (if (< dreg 0)
          (pl-owners-empty)
          (array-set! pl-owners dreg 0)))]
    [else (pl-owners-empty)]))

;; Sweep metadata for one emitted record, taken from the descriptor and (for a
;; corpus line) its raw text: compiler-backend-sweep-line-* in record form.
(define (pl-record-sweep [slot : (Array i64)] [index : i64]) : unit
  (let
    [start : i64 (array-ref slot pl-f-start)]
    [end : i64 (array-ref slot pl-f-end)]
    [ms : i64 (array-ref slot pl-f-mn-start)]
    [mlen : i64 (array-ref slot pl-f-mn-len)]
    [flags : i64 0]
    [cand : i64 pl-none]
    [read : i64 pl-none]
    [width : i64 8]
    [value : i64 0]
    (begin
      (when
        (= (array-ref slot pl-f-label) 1)
        (set! flags (bit-or flags pl-sw-label)))
      (when
        (and
          (= (array-ref slot pl-f-owned) 0)
          (= mlen 4)
          (= (pl-byte-at ms) 108)
          (= (pl-byte-at (+ ms 1)) 101)
          (= (pl-byte-at (+ ms 2)) 97)
          (= (pl-byte-at (+ ms 3)) 113))
        (set! flags (bit-or flags pl-sw-leaq)))
      (when
        (and
          (= (array-ref slot pl-f-owned) 0)
          (>= mlen 4)
          (= (pl-byte-at ms) 112)
          (= (pl-byte-at (+ ms 1)) 117)
          (= (pl-byte-at (+ ms 2)) 115)
          (= (pl-byte-at (+ ms 3)) 104))
        (set! flags (bit-or flags pl-sw-push)))
      (when
        (and
          (= (array-ref slot pl-f-owned) 0)
          (>= mlen 3)
          (= (pl-byte-at ms) 112)
          (= (pl-byte-at (+ ms 1)) 111)
          (= (pl-byte-at (+ ms 2)) 112))
        (set! flags (bit-or flags pl-sw-pop)))
      (when
        (and (>= mlen 4) (= (array-ref slot pl-f-owned) 0))
        (let
          [b0 : i64 (pl-byte-at ms)]
          [b1 : i64 (pl-byte-at (+ ms 1))]
          [b2 : i64 (pl-byte-at (+ ms 2))]
          (when
            (or
              (and (= b0 115) (= b1 117) (= b2 98))
              (and (= b0 97) (= b1 100) (= b2 100)))
            (let
              [operand : i64 (+ ms mlen)]
              (begin
                (while (and (< operand end) (= (pl-byte-at operand) 32))
                  (set! operand (+ operand 1)))
                (when
                  (and (= (pl-byte-at operand) 36) (pl-tail-is-rsp? end))
                  (let
                    [comma : i64 (pl-find-comma-space operand end)]
                    (when
                      (and
                        (> comma (+ operand 1))
                        (pl-decimal-valid? (+ operand 1) comma))
                      (begin
                        (set! flags (bit-or flags pl-sw-tracked))
                        (set! flags (bit-or flags pl-sw-rsp-dst))
                        (when (= b0 115) (set! flags (bit-or flags pl-sw-subq)))
                        (set! value (pl-decimal-value (+ operand 1) comma)))))))))))
      (when
        (and
          (= (array-ref slot pl-f-owned) 0)
          (pl-tail-is-rsp? end)
          (= (bit-and flags pl-sw-tracked) 0))
        (set! flags (bit-or flags pl-sw-rsp-dst)))
      (when
        (and (= (array-ref slot pl-f-owned) 0) (pl-indexed-rsp? start end))
        (set! flags (bit-or flags pl-sw-fatal)))
      (set! width (pl-access-width slot))
      (when
        (and
          (= (array-ref slot pl-f-movq) 1)
          (=
            (pl-memory-base
              (array-ref slot pl-f-dst-start)
              (array-ref slot pl-f-dst-end))
            2)
          (> (array-ref slot pl-f-dst-key) 0)
          (= (bit-and (array-ref slot pl-f-src-flags) pl-op-stack) 0))
        (set!
          cand
          (pl-rsp-displacement
            (array-ref slot pl-f-dst-start)
            (array-ref slot pl-f-dst-end))))
      (when
        (= cand pl-none)
        (set!
          read
          (if (= (array-ref slot pl-f-owned) 0)
            (pl-first-rsp-read start end)
            (pl-first-rsp-read
              (array-ref slot pl-f-src-start)
              (array-ref slot pl-f-src-end)))))
      (array-set! pl-rec-flags index flags)
      (array-set! pl-rec-cand index cand)
      (array-set! pl-rec-read index read)
      (array-set! pl-rec-width index width)
      (array-set! pl-rec-value index value))))

;; Does the line end with the bare `%rsp` destination operand?
(define (pl-tail-is-rsp? [end : i64]) : bool
  (and
    (>= end 4)
    (= (pl-byte-at (- end 4)) 37)
    (= (pl-byte-at (- end 3)) 114)
    (= (pl-byte-at (- end 2)) 115)
    (= (pl-byte-at (- end 1)) 112)))

;; `(%rsp,` -- an indexed stack reference the sweep cannot replay.
(define (pl-indexed-rsp? [start : i64] [end : i64]) : bool
  (let
    [i : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (<= (+ i 6) end))
        (begin
          (when
            (and
              (= (pl-byte-at i) 40)
              (= (pl-byte-at (+ i 1)) 37)
              (= (pl-byte-at (+ i 2)) 114)
              (= (pl-byte-at (+ i 3)) 115)
              (= (pl-byte-at (+ i 4)) 112)
              (= (pl-byte-at (+ i 5)) 44))
            (set! found true))
          (set! i (+ i 1))))
      found)))

;; Access width from the mnemonic's size suffix.
(define (pl-access-width [slot : (Array i64)]) : i64
  (if (= (array-ref slot pl-f-owned) 1)
    8
    (let
      [ms : i64 (array-ref slot pl-f-mn-start)]
      [mlen : i64 (array-ref slot pl-f-mn-len)]
      (if (< mlen 2)
        8
        (let
          [suffix : i64 (pl-byte-at (+ ms (- mlen 1)))]
          (cond
            [(= suffix 113) 8]
            [(= suffix 108) 4]
            [(= suffix 119) 2]
            [(= suffix 98) 1]
            [else 8]))))))

;; The displacement of an operand that ends in `(%rsp)`.
(define (pl-rsp-displacement [start : i64] [end : i64]) : i64
  (let
    [prefix-end : i64 (- end 6)]
    (cond
      [(= prefix-end start) 0]
      [(pl-decimal-valid? start prefix-end) (pl-decimal-value start prefix-end)]
      [else pl-none])))

;; The first `N(%rsp)` displacement in a byte range.
(define (pl-first-rsp-read [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [found : i64 pl-none]
    (begin
      (while (and (= found pl-none) (<= (+ i 6) end))
        (begin
          (when
            (and
              (= (pl-byte-at i) 40)
              (= (pl-byte-at (+ i 1)) 37)
              (= (pl-byte-at (+ i 2)) 114)
              (= (pl-byte-at (+ i 3)) 115)
              (= (pl-byte-at (+ i 4)) 112)
              (= (pl-byte-at (+ i 5)) 41))
            (let
              [digits : i64 i]
              (begin
                (while (and
                  (> digits start)
                  (let
                    [b : i64 (pl-byte-at (- digits 1))]
                    (or (and (>= b 48) (<= b 57)) (= b 45))))
                  (set! digits (- digits 1)))
                (set!
                  found
                  (if (= digits i)
                    0
                    (if (pl-decimal-valid? digits i)
                      (pl-decimal-value digits i)
                      0))))))
          (set! i (+ i 1))))
      found)))

;; compiler-backend-peephole-emit-line-desc-record: reload elision, the
;; cross-register reuse rewrite, and the record push.
(define (pl-emit-record [slot : (Array i64)] [prev-abort : i64]) : unit
  (if (= (array-ref slot pl-f-movq) 1)
    (let
      [src-reg : i64 (array-ref slot pl-f-src-reg)]
      [dst-reg : i64 (array-ref slot pl-f-dst-reg)]
      [src-key : i64 (array-ref slot pl-f-src-key)]
      [dst-key : i64 (array-ref slot pl-f-dst-key)]
      [is-slot : bool (not (= src-key 0))]
      [dst-owns : bool
        (and is-slot (>= dst-reg 0) (= (array-ref pl-owners dst-reg) src-key))]
      [reuse : i64
        (if (and is-slot (not dst-owns) (>= dst-reg 0))
          (pl-owners-find-reg src-key dst-reg)
          -1)]
      (begin
        (cond
          [dst-owns
            (begin
              (set! pl-elided (+ pl-elided 1))
              (set! pl-dropped (+ pl-dropped 1)))]
          [(>= reuse 0)
            (begin
              (set! pl-reused (+ pl-reused 1))
              (pl-push-record slot)
              ;; The pushed line becomes `movq %rY, DST`, a register source, so
              ;; it no longer reads the frame slot the sweep would have seen.
              (array-set! pl-rec-read (- pl-rec-len 1) pl-none))]
          [else (pl-push-record slot)])
        (pl-owners-transfer src-reg dst-reg src-key dst-key)))
    (begin
      (pl-push-record slot)
      (pl-clobber-owners slot prev-abort))))

(define (pl-push-record [slot : (Array i64)]) : unit
  (let
    [index : i64 pl-rec-len]
    (begin
      (array-set! pl-rec-owned index (array-ref slot pl-f-owned))
      (array-set! pl-rec-src-start index (array-ref slot pl-f-src-start))
      (array-set! pl-rec-src-end index (array-ref slot pl-f-src-end))
      (array-set! pl-rec-dst-start index (array-ref slot pl-f-dst-start))
      (array-set! pl-rec-dst-end index (array-ref slot pl-f-dst-end))
      (array-set! pl-rec-live index 1)
      (pl-record-sweep slot index)
      (set! pl-rec-len (+ pl-rec-len 1))
      (set! pl-kept (+ pl-kept 1)))))

;; compiler-backend-deadstore-sweep-records! / -sweep-region-records!: replay
;; the rsp delta, collect pure frame stores and frame reads, then drop stores
;; that no later read observes and that no `leaq` took the address of.
(define (pl-sweep-region) : unit
  (let
    [delta : i64 0]
    [sweepable : bool true]
    [watermark : i64 pl-none]
    [cand-count : i64 0]
    [read-count : i64 0]
    [i : i64 0]
    (begin
      (while (and sweepable (< i pl-rec-len))
        (let
          [flags : i64 (array-ref pl-rec-flags i)]
          [cand : i64 (array-ref pl-rec-cand i)]
          [read : i64 (array-ref pl-rec-read i)]
          (begin
            (if (not (= (bit-and flags pl-sw-label) 0))
              (set! delta 0)
              (begin
                (when
                  (not (= (bit-and flags pl-sw-fatal) 0))
                  (set! sweepable false))
                (when
                  (and
                    (not (= (bit-and flags pl-sw-leaq) 0))
                    (not (= read pl-none)))
                  (let
                    [address : i64 (- read delta)]
                    (when (< address watermark) (set! watermark address))))
                (when
                  (and (not (= cand pl-none)) (< cand-count 4096))
                  (begin
                    (array-set! pl-sweep-cand-pos cand-count i)
                    (array-set! pl-sweep-cand-off cand-count (- cand delta))
                    (set! cand-count (+ cand-count 1))))
                (when
                  (and
                    (= cand pl-none)
                    (not (= read pl-none))
                    (= (bit-and flags pl-sw-leaq) 0)
                    (< read-count 4096))
                  (begin
                    (array-set! pl-sweep-read-lo read-count (- read delta))
                    (array-set!
                      pl-sweep-read-hi
                      read-count
                      (+ (- read delta) (array-ref pl-rec-width i)))
                    (set! read-count (+ read-count 1))))
                (when
                  (not (= (bit-and flags pl-sw-push) 0))
                  (set! delta (+ delta 8)))
                (when
                  (not (= (bit-and flags pl-sw-pop) 0))
                  (set! delta (- delta 8)))
                (when
                  (not (= (bit-and flags pl-sw-rsp-dst) 0))
                  (if (not (= (bit-and flags pl-sw-tracked) 0))
                    (if (not (= (bit-and flags pl-sw-subq) 0))
                      (set! delta (+ delta (array-ref pl-rec-value i)))
                      (set! delta (- delta (array-ref pl-rec-value i))))
                    (set! sweepable false)))))
            (set! i (+ i 1)))))
      (when
        (and sweepable (> cand-count 0))
        (let
          [k : i64 0]
          (while (< k cand-count)
            (let
              [offset : i64 (array-ref pl-sweep-cand-off k)]
              [position : i64 (array-ref pl-sweep-cand-pos k)]
              [r : i64 0]
              [observed : bool false]
              (begin
                (when
                  (< offset watermark)
                  (begin
                    (while (and (not observed) (< r read-count))
                      (begin
                        (when
                          (and
                            (< (array-ref pl-sweep-read-lo r) (+ offset 8))
                            (< offset (array-ref pl-sweep-read-hi r)))
                          (set! observed true))
                        (set! r (+ r 1))))
                    (unless
                      observed
                      (begin
                        (array-set! pl-rec-live position 0)
                        (set! pl-swept (+ pl-swept 1))
                        (set! pl-kept (- pl-kept 1))))))
                (set! k (+ k 1))))))))))

;; compiler-backend-drop-fallthrough-jumps
(define (pl-drop-fallthrough [start : i64] [stop : i64]) : unit
  (let
    [i : i64 start]
    [pending? : bool false]
    [target-start : i64 0]
    [target-stop : i64 0]
    (while (< i stop)
      (let
        [end : i64 (pl-line-end i stop)]
        [next-start : i64
          (if (< end stop)
            (+ end 1)
            end)]
        [consumed? : bool false]
        (begin
          (when
            pending?
            (if (pl-label-def-line? i end)
              (begin
                (set! consumed? true)
                (when
                  (pl-ranges-eq? target-start target-stop i (- end 1))
                  (begin
                    (set! pl-fallthrough (+ pl-fallthrough 1))
                    (set! pending? false))))
              (set! pending? false)))
          (unless
            consumed?
            (when
              (pl-direct-jmp-line? i end)
              (begin
                (set! pending? true)
                (set! target-start (+ i 8))
                (set! target-stop end))))
          (set! i next-start))))))

;; compiler-backend-asm-label-def-line?
(define (pl-label-def-line? [start : i64] [end : i64]) : bool
  (if (< (- end start) 2)
    false
    (if (not (= (pl-byte-at (- end 1)) 58))
      false
      (let
        [limit : i64 (- end 1)]
        [i : i64 start]
        [ok : bool true]
        (begin
          (while (and ok (< i limit))
            (let
              [b : i64 (pl-byte-at i)]
              (begin
                (when (or (= b 32) (= b 9) (= b 58)) (set! ok false))
                (set! i (+ i 1)))))
          ok)))))

;; compiler-backend-asm-direct-jmp-line?
(define (pl-direct-jmp-line? [start : i64] [end : i64]) : bool
  (let
    [operand-start : i64 (+ start 8)]
    (if (<= end operand-start)
      false
      (if (not
        (and
          (= (pl-byte-at start) 32)
          (= (pl-byte-at (+ start 1)) 32)
          (= (pl-byte-at (+ start 2)) 32)
          (= (pl-byte-at (+ start 3)) 32)
          (= (pl-byte-at (+ start 4)) 106)
          (= (pl-byte-at (+ start 5)) 109)
          (= (pl-byte-at (+ start 6)) 112)
          (= (pl-byte-at (+ start 7)) 32)))
        false
        (let
          [i : i64 operand-start]
          [ok : bool true]
          (begin
            (while (and ok (< i end))
              (let
                [b : i64 (pl-byte-at i)]
                (begin
                  (when
                    (or (= b 32) (= b 9) (= b 42) (= b 37) (= b 40) (= b 44))
                    (set! ok false))
                  (set! i (+ i 1)))))
            ok))))))

;; compiler-backend-peephole-asm-once-records-chunks over one chunk.
(define (pl-run-chunk [start : i64] [stop : i64]) : i64
  (let
    [i : i64 start]
    [has-pending : bool false]
    [prev-abort : i64 0]
    [hash : i64 pl-hash-basis]
    (begin
      (set! pl-rec-len 0)
      (pl-owners-empty)
      (pl-drop-fallthrough start stop)
      (while (< i stop)
        (let
          [end : i64 (pl-line-end i stop)]
          [next-start : i64
            (if (< end stop)
              (+ end 1)
              end)]
          [newline : i64
            (if (< end stop)
              1
              0)]
          (begin
            (if has-pending
              (let
                [action : i64 0]
                (begin
                  (pl-parse-line pl-next i end (= newline 1))
                  (set! action (pl-pair-action pl-pending pl-next))
                  (cond
                    [(= action 1)
                      (begin
                        (set! pl-rule1 (+ pl-rule1 1))
                        (set! pl-dropped (+ pl-dropped 1))
                        (pl-copy-line pl-pending pl-next))]
                    [(= action 2)
                      (begin
                        (set! pl-rule2 (+ pl-rule2 1))
                        (set! pl-dropped (+ pl-dropped 1)))]
                    [(= action 3)
                      (begin
                        (set! pl-rule3 (+ pl-rule3 1))
                        (pl-emit-record pl-pending prev-abort)
                        (set! prev-abort (array-ref pl-pending pl-f-abort))
                        (pl-owned-line
                          pl-pending
                          (array-ref pl-pending pl-f-src-start)
                          (array-ref pl-pending pl-f-src-end)
                          (array-ref pl-next pl-f-dst-start)
                          (array-ref pl-next pl-f-dst-end)
                          newline))]
                    [(= action 4)
                      (begin
                        (set! pl-rule4 (+ pl-rule4 1))
                        (pl-owned-line
                          pl-pending
                          (array-ref pl-next pl-f-src-start)
                          (array-ref pl-next pl-f-src-end)
                          (array-ref pl-next pl-f-dst-start)
                          (array-ref pl-next pl-f-dst-end)
                          newline))]
                    [else
                      (begin
                        (pl-emit-record pl-pending prev-abort)
                        (set! prev-abort (array-ref pl-pending pl-f-abort))
                        (pl-copy-line pl-pending pl-next))])))
              (begin
                (set! has-pending true)
                (pl-parse-line pl-pending i end (= newline 1))))
            (set! i next-start))))
      (when
        (and has-pending (not (pl-self-move? pl-pending)))
        (pl-emit-record pl-pending prev-abort))
      (pl-sweep-region)
      (set! hash (pl-mix hash pl-rec-len))
      (set! hash (pl-mix hash pl-kept))
      (set! hash (pl-mix hash pl-dropped))
      (set! hash (pl-mix hash pl-rule1))
      (set! hash (pl-mix hash pl-rule2))
      (set! hash (pl-mix hash pl-rule3))
      (set! hash (pl-mix hash pl-rule4))
      (set! hash (pl-mix hash pl-elided))
      (set! hash (pl-mix hash pl-reused))
      (set! hash (pl-mix hash pl-fallthrough))
      (pl-mix hash pl-swept))))

(define (pl-bench [path : String] [rounds : i64]) : i64
  (let
    [chunks : i64 0]
    [max-lines : i64 1]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 pl-hash-basis]
    (begin
      (set!
        pl-text
        (byte_buf.to-string (io.read-file-or (& path) (byte_buf.new))))
      (set! pl-len (string.string-length pl-text))
      (set! acc (pl-mix acc pl-len))
      (set! pl-chunk-start (array.make-array i64 (+ (/ pl-len 16) 4)))
      (set! pl-chunk-end (array.make-array i64 (+ (/ pl-len 16) 4)))
      (let
        [i : i64 0]
        [chunk-begin : i64 0]
        [lines : i64 0]
        (begin
          (while (< i pl-len)
            (let
              [end : i64 (pl-line-end i pl-len)]
              [next-start : i64
                (if (< end pl-len)
                  (+ end 1)
                  end)]
              (begin
                (when
                  (and (pl-globl-line? i end) (> i chunk-begin))
                  (begin
                    (array-set! pl-chunk-start chunks chunk-begin)
                    (array-set! pl-chunk-end chunks i)
                    (when (> lines max-lines) (set! max-lines lines))
                    (set! chunks (+ chunks 1))
                    (set! chunk-begin i)
                    (set! lines 0)))
                (set! lines (+ lines 1))
                (set! i next-start))))
          (when
            (> pl-len chunk-begin)
            (begin
              (array-set! pl-chunk-start chunks chunk-begin)
              (array-set! pl-chunk-end chunks pl-len)
              (when (> lines max-lines) (set! max-lines lines))
              (set! chunks (+ chunks 1))))))
      (set! pl-chunk-count chunks)
      (set! pl-rec-owned (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-src-start (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-src-end (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-dst-start (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-dst-end (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-flags (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-cand (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-read (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-width (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-value (array.make-array i64 (+ max-lines 2)))
      (set! pl-rec-live (array.make-array i64 (+ max-lines 2)))
      (set! pl-sweep-cand-pos (array.make-array i64 4097))
      (set! pl-sweep-cand-off (array.make-array i64 4097))
      (set! pl-sweep-read-lo (array.make-array i64 4097))
      (set! pl-sweep-read-hi (array.make-array i64 4097))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          (begin
            (set! acc (pl-mix acc round))
            (set! pl-kept 0)
            (set! pl-dropped 0)
            (set! pl-rule1 0)
            (set! pl-rule2 0)
            (set! pl-rule3 0)
            (set! pl-rule4 0)
            (set! pl-elided 0)
            (set! pl-reused 0)
            (set! pl-fallthrough 0)
            (set! pl-swept 0)
            (while (< step chunks)
              (begin
                (set! index (+ start step))
                (when (>= index chunks) (set! index (- index chunks)))
                (set!
                  acc
                  (pl-mix
                    acc
                    (pl-run-chunk
                      (array-ref pl-chunk-start index)
                      (array-ref pl-chunk-end index))))
                (set! step (+ step 1))))
            (set! start (+ start 1))
            (when (>= start chunks) (set! start 0))
            (set! round (+ round 1)))))
      acc)))

;; A chunk boundary: the first non-space bytes of the line are `.globl`.
(define (pl-globl-line? [start : i64] [end : i64]) : bool
  (let
    [i : i64 start]
    (begin
      (while (and (< i end) (= (pl-byte-at i) 32))
        (set! i (+ i 1)))
      (and
        (<= (+ i 6) end)
        (= (pl-byte-at i) 46)
        (= (pl-byte-at (+ i 1)) 103)
        (= (pl-byte-at (+ i 2)) 108)
        (= (pl-byte-at (+ i 3)) 111)
        (= (pl-byte-at (+ i 4)) 98)
        (= (pl-byte-at (+ i 5)) 108)))))

;; The corpus path and round count are read defensively so that a run with no
;; arguments, or with a corpus this checkout does not have, still prints one
;; deterministic checksum and exits 0 -- the same value and the same exit status
;; the C baseline produces from `argc > 1 ? argv[1] : ""` and a failed `fopen`.
;; An unreadable corpus is an empty text, which yields zero chunks and folds
;; only the round counter.
(define (main) : i64
  (let
    [count : i64 (io.arg-count)]
    [path : String
      (if (> count 1)
        (io.arg 1)
        "")]
    [rounds : i64
      (if (> count 2)
        (string.>int (io.arg 2))
        0)]
    (begin
      (io.print (pl-bench path rounds))
      0)))