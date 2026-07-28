;# benchmarks/liveness_scan/bench.tl - the compiler's backward liveness fixpoint.
;#
;# Equivalent to benchmarks/liveness_scan/baseline.c. The kernel is extracted
;# from src/compiler_liveness.tl and the input is REAL dataflow input: the
;# corpus in benchmarks/liveness_scan/data/cfgs.txt holds the per-function CFGs
;# and use/def sets the compiler's own liveness pass consumes when it lowers
;# src/compiler_liveness.tl (2087 functions, 12172 blocks, that module plus
;# every module it imports), captured from `typelisp compile --dump-ir` by
;# benchmarks/liveness_scan/tools/export_cfgs.py without modifying the compiler.
;# The block order in the corpus is the dump order, which is the lowering's
;# deterministic reverse postorder - the order the worklist walks backwards.
;#
;# What it mirrors, function for function:
;#   `compiler-live-fixpoint`  the ordinary backward pass: seed every block
;#     pending, pick the highest pending index, recompute, and on a change store
;#     the result and re-enqueue predecessors.
;#   `compiler-live-worklist-seed!`, `compiler-live-worklist-pick!` (a linear
;#     scan down from the last block), `compiler-live-worklist-enqueue-
;#     predecessors!`.
;#   `compiler-live-recompute-block-graph`  live-out is the union of the
;#     successors' live-in (`compiler-live-successor-live-out-graph-loop`), and
;#     live-in is `uses | (live-out - defs)`.
;#   `compiler-live-fixpoint-ep` and `compiler-live-recompute-block-graph-ep`
;#     reached from `compiler-live-analyze-blocks-edge-precise`: the same pass
;#     over blocks built by `compiler-live-build-block-nophi` (phi operands are
;#     not block uses) with each block's `phi-out` set unioned into its live-out.
;#     `phi-out` is what `compiler-live-phi-out-add-inputs!` accumulates: every
;#     phi input `(%v, predLabel)` puts `%v` into phi-out of the predecessor.
;#   `compiler-live-block-liveness-eq?`  the change test compares live-in and
;#     live-out.
;#   `compiler-live-predecessors-build` / `compiler-live-predecessor-counts-add!`
;#     / `-items-make` / `-fill!`  the predecessor index, built by counting then
;#     filling.
;#   `compiler-live-set-word-bits` = 32, `-word-shift` = 5, `-word-mask` = 31:
;#     the compiler packs THIRTY-TWO bits per i64 word, not sixty-four, so the
;#     bitsets here do the same. A function's universe is its `vars` count, so
;#     the corpus spans 1 to 4088 words per set (median 1, p90 3).
;#   `compiler-live-set-count` + `compiler-live-set-trim-length`  the population
;#     count walks only up to the highest non-zero word, because the compiler's
;#     sets are canonical and never carry a trailing zero word. The per-word
;#     count itself clears the lowest set bit rather than testing all 32 bit
;#     positions the way `compiler-live-set-word-count-bits` does; see the note
;#     on `ln-set-count` for why.
;#
;# What it deliberately leaves out: the compiler's sets are immutable, trimmed,
;# allocated values, and `compiler-live-set-union` / `-minus` probe for a change
;# before allocating a result. Here every set is a fixed-width dense slice of
;# one flat word array, so the same dataflow runs without an allocator in the
;# loop. Instruction-level `instr-after` scanning (`compiler-live-fill-instr-
;# after-graph-*`) is out of scope; this row is the block-level fixpoint.
;#
;# A round runs both entries over every function: the ordinary pass, then the
;# edge-precise pass, each from a cleared live-in/live-out state, and folds
;# every block's live-in population count into a wrapping 64-bit accumulator.
;# The corpus path and round count are runtime arguments, so nothing can be
;# constant folded, and all arithmetic wraps modulo 2^64 in both languages, so
;# the printed decimal matches the C baseline's `%lld`.
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

;; `compiler-live-set-word-shift` / `-word-mask`: the compiler's
;; `compiler-live-set-word-bits` is THIRTY-TWO, so an i64 word carries 32 set
;; members, not 64.
(define ln-word-shift : i64
  5)
(define ln-word-mask : i64
  31)

(define (ln-word-index [value : i64]) : i64
  (shr value ln-word-shift))

(define (ln-bit-mask [value : i64]) : i64
  (shl 1 (bit-and value ln-word-mask)))

(define (ln-words-for [vars : i64]) : i64
  (shr (+ vars ln-word-mask) ln-word-shift))

(define (ln-set-bit! [words : (Array i64)] [base : i64] [value : i64]) : unit
  (let
    [slot : i64 (+ base (ln-word-index value))]
    (array-set! words slot (bit-or (array-ref words slot) (ln-bit-mask value)))))

;; ---- corpus parsing ----
;; The corpus is a whitespace-separated stream of non-negative decimals and
;; nothing else, so one scanner serves both implementations.
(define (ln-digit? [c : i64]) : bool
  (and (>= c 48) (<= c 57)))

(define (ln-count-tokens [buf : (Array u8)] [n : i64]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    [inside : bool false]
    (begin
      (while (< i n)
        (let
          [c : i64 (cast (array-ref buf i) : i64)]
          (begin
            (if (ln-digit? c)
              (if inside
                unit
                (begin
                  (set! count (+ count 1))
                  (set! inside true)))
              (set! inside false))
            (set! i (+ i 1)))))
      count)))

(define (ln-fill-tokens [buf : (Array u8)] [n : i64] [tokens : (Array i64)]) : unit
  (let
    [i : i64 0]
    [count : i64 0]
    [value : i64 0]
    [inside : bool false]
    (begin
      (while (< i n)
        (let
          [c : i64 (cast (array-ref buf i) : i64)]
          (begin
            (if (ln-digit? c)
              (begin
                (set! value (+ (* value 10) (- c 48)))
                (set! inside true))
              (when
                inside
                (begin
                  (array-set! tokens count value)
                  (set! count (+ count 1))
                  (set! value 0)
                  (set! inside false))))
            (set! i (+ i 1)))))
      (when
        inside
        (begin
          (array-set! tokens count value)
          (set! count (+ count 1))))
      unit)))

;; ---- the dataflow ----
;; `compiler-live-successor-live-out-graph-loop` then the phi-out union of
;; `compiler-live-recompute-block-graph-ep`, into a scratch word slice.
(define (ln-live-out-into!
  [scratch : (Array i64)]
  [words : i64]
  [g : i64]
  [succ-start : (Array i64)]
  [succ-items : (Array i64)]
  [live-in : (Array i64)]
  [word-base : i64]
  [block-base : i64]
  [phi-out : (Array i64)]
  [with-phi-out : bool]) : unit
  (let
    [k : i64 0]
    [stop : i64 (array-ref succ-start (+ g 1))]
    [slot : i64 (array-ref succ-start g)]
    (begin
      (while (< k words)
        (begin
          (array-set! scratch k 0)
          (set! k (+ k 1))))
      (while (< slot stop)
        (let
          [succ : i64 (array-ref succ-items slot)]
          [succ-base : i64 (+ word-base (* (- succ block-base) words))]
          [i : i64 0]
          (begin
            (while (< i words)
              (begin
                (array-set!
                  scratch
                  i
                  (bit-or
                    (array-ref scratch i)
                    (array-ref live-in (+ succ-base i))))
                (set! i (+ i 1))))
            (set! slot (+ slot 1)))))
      (when
        with-phi-out
        (let
          [self-base : i64 (+ word-base (* (- g block-base) words))]
          [i : i64 0]
          (while (< i words)
            (begin
              (array-set!
                scratch
                i
                (bit-or
                  (array-ref scratch i)
                  (array-ref phi-out (+ self-base i))))
              (set! i (+ i 1))))))
      unit)))

;; `compiler-live-recompute-block-graph`: live-in is `uses | (live-out - defs)`.
;; The result is compared against the stored sets (`compiler-live-block-
;; liveness-eq?`) and only written back when it differs.
(define (ln-recompute!
  [g : i64]
  [words : i64]
  [word-base : i64]
  [block-base : i64]
  [succ-start : (Array i64)]
  [succ-items : (Array i64)]
  [uses : (Array i64)]
  [defs : (Array i64)]
  [phi-out : (Array i64)]
  [live-in : (Array i64)]
  [live-out : (Array i64)]
  [scratch-out : (Array i64)]
  [scratch-in : (Array i64)]
  [with-phi-out : bool]) : bool
  (let
    [self-base : i64 (+ word-base (* (- g block-base) words))]
    [i : i64 0]
    [changed : bool false]
    (begin
      (ln-live-out-into!
        scratch-out
        words
        g
        succ-start
        succ-items
        live-in
        word-base
        block-base
        phi-out
        with-phi-out)
      (while (< i words)
        (begin
          (array-set!
            scratch-in
            i
            (bit-or
              (array-ref uses (+ self-base i))
              (bit-and
                (array-ref scratch-out i)
                (bit-xor (array-ref defs (+ self-base i)) -1))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (and (< i words) (not changed))
        (begin
          (when
            (or
              (!= (array-ref scratch-in i) (array-ref live-in (+ self-base i)))
              (!=
                (array-ref scratch-out i)
                (array-ref live-out (+ self-base i))))
            (set! changed true))
          (set! i (+ i 1))))
      (when
        changed
        (let
          [k : i64 0]
          (while (< k words)
            (begin
              (array-set! live-in (+ self-base k) (array-ref scratch-in k))
              (array-set! live-out (+ self-base k) (array-ref scratch-out k))
              (set! k (+ k 1))))))
      changed)))

;; `compiler-live-fixpoint` / `compiler-live-fixpoint-ep` over one function.
(define (ln-fixpoint!
  [block-base : i64]
  [blocks : i64]
  [words : i64]
  [word-base : i64]
  [succ-start : (Array i64)]
  [succ-items : (Array i64)]
  [pred-start : (Array i64)]
  [pred-items : (Array i64)]
  [uses : (Array i64)]
  [defs : (Array i64)]
  [phi-out : (Array i64)]
  [live-in : (Array i64)]
  [live-out : (Array i64)]
  [pending : (Array i64)]
  [scratch-out : (Array i64)]
  [scratch-in : (Array i64)]
  [with-phi-out : bool]) : unit
  (let
    [b : i64 0]
    [done : bool false]
    (begin
      ;; `compiler-live-worklist-seed!` plus the cleared entry state every
      ;; `compiler-live-build-block` starts from.
      (while (< b blocks)
        (let
          [self-base : i64 (+ word-base (* b words))]
          [k : i64 0]
          (begin
            (array-set! pending (+ block-base b) 1)
            (while (< k words)
              (begin
                (array-set! live-in (+ self-base k) 0)
                (array-set! live-out (+ self-base k) 0)
                (set! k (+ k 1))))
            (set! b (+ b 1)))))
      (while (not done)
        (let
          [index : i64 -1]
          [i : i64 (- blocks 1)]
          (begin
            ;; `compiler-live-worklist-pick!`: scan down for the last pending
            ;; block, which is the backward order the lowering's layout wants.
            (while (and (>= i 0) (< index 0))
              (begin
                (when
                  (= (array-ref pending (+ block-base i)) 1)
                  (begin
                    (array-set! pending (+ block-base i) 0)
                    (set! index i)))
                (set! i (- i 1))))
            (if (< index 0)
              (set! done true)
              (when
                (ln-recompute!
                  (+ block-base index)
                  words
                  word-base
                  block-base
                  succ-start
                  succ-items
                  uses
                  defs
                  phi-out
                  live-in
                  live-out
                  scratch-out
                  scratch-in
                  with-phi-out)
                ;; `compiler-live-worklist-enqueue-predecessors!`
                (let
                  [g : i64 (+ block-base index)]
                  [slot : i64 (array-ref pred-start g)]
                  [stop : i64 (array-ref pred-start (+ g 1))]
                  (while (< slot stop)
                    (begin
                      (array-set! pending (array-ref pred-items slot) 1)
                      (set! slot (+ slot 1))))))))))
      unit)))

;; `compiler-live-set-trim-length` then `compiler-live-set-count` over the
;; trimmed prefix. The compiler's `compiler-live-set-word-count-bits` tests all
;; thirty-two bit positions of every word; this counts by clearing the lowest
;; set bit instead, so the checksum costs work proportional to the live-in sets
;; rather than to the universe. Same value, and it keeps this row a measurement
;; of the fixpoint: with the compiler's per-bit spelling the fold alone is 78%
;; of the TypeLisp row.
(define (ln-set-count [words-array : (Array i64)] [base : i64] [words : i64]) : i64
  (let
    [n : i64 words]
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (and (> n 0) (= (array-ref words-array (+ base (- n 1))) 0))
        (set! n (- n 1)))
      (while (< i n)
        (let
          [bits : i64 (array-ref words-array (+ base i))]
          (begin
            (while (!= bits 0)
              (begin
                (set! bits (bit-and bits (- bits 1)))
                (set! count (+ count 1))))
            (set! i (+ i 1)))))
      count)))

(define (ln-fold-live-in
  [live-in : (Array i64)]
  [word-base : i64]
  [blocks : i64]
  [words : i64]
  [seed-acc : i64]) : i64
  (let
    [b : i64 0]
    [acc : i64 seed-acc]
    (begin
      (while (< b blocks)
        (begin
          (set!
            acc
            (+
              (* acc 1000003)
              (*
                (ln-set-count live-in (+ word-base (* b words)) words)
                2654435761)))
          (set! b (+ b 1))))
      acc)))

(define (ln-bench [path : String] [rounds : i64]) : i64
  (let
    [source : String (io.read-file path)]
    [text : (Array u8)
      (byte_buf.bytes-to-array (byte_buf.str-as-bytes (& source)))]
    [n : i64 (array-length text)]
    [token-count : i64 (ln-count-tokens text n)]
    [tokens : (Array i64) (array.make-array i64 (+ token-count 1))]
    [functions : i64 0]
    [total-blocks : i64 0]
    [total-words : i64 0]
    [total-succ : i64 0]
    [max-words : i64 1]
    [p : i64 0]
    (begin
      (ln-fill-tokens text n tokens)
      ;; Sizing pass over the token stream.
      (set! p 1)
      (set! functions (array-ref tokens p))
      (set! p (+ p 1))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [vars : i64 (array-ref tokens p)]
            [blocks : i64 (array-ref tokens (+ p 1))]
            [words : i64 (ln-words-for vars)]
            [b : i64 0]
            (begin
              (set! p (+ p 2))
              (set! total-blocks (+ total-blocks blocks))
              (set! total-words (+ total-words (* blocks words)))
              (when (> words max-words) (set! max-words words))
              (while (< b blocks)
                (let
                  [k : i64 0]
                  (begin
                    (while (< k 5)
                      (let
                        [c : i64 (array-ref tokens p)]
                        (begin
                          (when (= k 0) (set! total-succ (+ total-succ c)))
                          (set! p (+ p 1 c))
                          (set! k (+ k 1)))))
                    (set! b (+ b 1)))))
              (set! f (+ f 1))))))
      (let
        [fn-block-base : (Array i64) (array.make-array i64 (+ functions 1))]
        [fn-word-base : (Array i64) (array.make-array i64 (+ functions 1))]
        [fn-blocks : (Array i64) (array.make-array i64 (+ functions 1))]
        [fn-words : (Array i64) (array.make-array i64 (+ functions 1))]
        [succ-start : (Array i64) (array.make-array i64 (+ total-blocks 1))]
        [succ-items : (Array i64) (array.make-array i64 (+ total-succ 1))]
        [pred-start : (Array i64) (array.make-array i64 (+ total-blocks 2))]
        [pred-items : (Array i64) (array.make-array i64 (+ total-succ 1))]
        [pred-cursor : (Array i64) (array.make-array i64 (+ total-blocks 1))]
        [uses : (Array i64) (array.make-array i64 (+ total-words 1))]
        [uses-nophi : (Array i64) (array.make-array i64 (+ total-words 1))]
        [defs : (Array i64) (array.make-array i64 (+ total-words 1))]
        [phi-out : (Array i64) (array.make-array i64 (+ total-words 1))]
        [live-in : (Array i64) (array.make-array i64 (+ total-words 1))]
        [live-out : (Array i64) (array.make-array i64 (+ total-words 1))]
        [pending : (Array i64) (array.make-array i64 (+ total-blocks 1))]
        [scratch-out : (Array i64) (array.make-array i64 (+ max-words 1))]
        [scratch-in : (Array i64) (array.make-array i64 (+ max-words 1))]
        [block-base : i64 0]
        [word-base : i64 0]
        [succ-cursor : i64 0]
        [round : i64 0]
        [acc : i64 0]
        (begin
          ;; Fill pass over the token stream.
          (set! p 2)
          (let
            [f : i64 0]
            (while (< f functions)
              (let
                [vars : i64 (array-ref tokens p)]
                [blocks : i64 (array-ref tokens (+ p 1))]
                [words : i64 (ln-words-for vars)]
                [b : i64 0]
                (begin
                  (set! p (+ p 2))
                  (array-set! fn-block-base f block-base)
                  (array-set! fn-word-base f word-base)
                  (array-set! fn-blocks f blocks)
                  (array-set! fn-words f words)
                  (while (< b blocks)
                    (let
                      [g : i64 (+ block-base b)]
                      [self-base : i64 (+ word-base (* b words))]
                      [count : i64 0]
                      [j : i64 0]
                      (begin
                        (array-set! succ-start g succ-cursor)
                        (set! count (array-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (array-set!
                              succ-items
                              succ-cursor
                              (+ block-base (array-ref tokens p)))
                            (set! succ-cursor (+ succ-cursor 1))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (array-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit! uses self-base (array-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (array-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit!
                              uses-nophi
                              self-base
                              (array-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (array-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit! defs self-base (array-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (array-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit! phi-out self-base (array-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! b (+ b 1)))))
                  (set! block-base (+ block-base blocks))
                  (set! word-base (+ word-base (* blocks words)))
                  (set! f (+ f 1))))))
          (array-set! succ-start total-blocks succ-cursor)
          ;; `compiler-live-predecessors-build`: count, then fill.
          (let
            [i : i64 0]
            (begin
              (while (< i succ-cursor)
                (let
                  [target : i64 (array-ref succ-items i)]
                  (begin
                    (array-set!
                      pred-cursor
                      target
                      (+ (array-ref pred-cursor target) 1))
                    (set! i (+ i 1)))))
              (set! i 0)
              (let
                [running : i64 0]
                (begin
                  (while (< i total-blocks)
                    (begin
                      (array-set! pred-start i running)
                      (set! running (+ running (array-ref pred-cursor i)))
                      (array-set! pred-cursor i (array-ref pred-start i))
                      (set! i (+ i 1))))
                  (array-set! pred-start total-blocks running)))
              (set! i 0)
              (while (< i total-blocks)
                (let
                  [slot : i64 (array-ref succ-start i)]
                  [stop : i64 (array-ref succ-start (+ i 1))]
                  (begin
                    (while (< slot stop)
                      (let
                        [target : i64 (array-ref succ-items slot)]
                        [at : i64 (array-ref pred-cursor target)]
                        (begin
                          (array-set! pred-items at i)
                          (array-set! pred-cursor target (+ at 1))
                          (set! slot (+ slot 1)))))
                    (set! i (+ i 1)))))))
          (while (< round rounds)
            (let
              [f : i64 0]
              (begin
                (while (< f functions)
                  (let
                    [base : i64 (array-ref fn-block-base f)]
                    [blocks : i64 (array-ref fn-blocks f)]
                    [words : i64 (array-ref fn-words f)]
                    [wbase : i64 (array-ref fn-word-base f)]
                    (begin
                      ;; `compiler-live-analyze-function`: the ordinary pass.
                      (ln-fixpoint!
                        base
                        blocks
                        words
                        wbase
                        succ-start
                        succ-items
                        pred-start
                        pred-items
                        uses
                        defs
                        phi-out
                        live-in
                        live-out
                        pending
                        scratch-out
                        scratch-in
                        false)
                      (set!
                        acc
                        (ln-fold-live-in live-in wbase blocks words acc))
                      ;; `compiler-live-analyze-blocks-edge-precise`.
                      (ln-fixpoint!
                        base
                        blocks
                        words
                        wbase
                        succ-start
                        succ-items
                        pred-start
                        pred-items
                        uses-nophi
                        defs
                        phi-out
                        live-in
                        live-out
                        pending
                        scratch-out
                        scratch-in
                        true)
                      (set!
                        acc
                        (ln-fold-live-in live-in wbase blocks words acc))
                      (set! f (+ f 1)))))
                (set! round (+ round 1)))))
          (+ (* acc 1000003) total-blocks))))))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (ln-bench path rounds))
      0)))