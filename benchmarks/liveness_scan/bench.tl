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
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import liveness_storage as storage)

(defmacro (ln-ref [items : Expr] [index : Expr]) : Expr
  `(storage.i64-get-mut ,items ,index))

(defmacro (ln-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(storage.i64-set! ,items ,index ,value))

(defmacro (ln-owner-ref [items : Expr] [index : Expr]) : Expr
  `(storage.i64-get (& ,items) ,index))

(defmacro (ln-owner-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(storage.i64-set! (&mut ,items) ,index ,value))

(defmacro (ln-owner-slice [items : Expr]) : Expr
  `(&mut ,items))

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

(define (ln-set-bit!
  [words : (&mut words storage.I64Buffer)]
  [base : i64]
  [value : i64]) : unit
  (let
    [slot : i64 (+ base (ln-word-index value))]
    (ln-set! words slot (bit-or (ln-ref words slot) (ln-bit-mask value)))))

;; ---- corpus parsing ----
;; The corpus is a whitespace-separated stream of non-negative decimals and
;; nothing else, so one scanner serves both implementations.
(define (ln-digit? [c : i64]) : bool
  (and (>= c 48) (<= c 57)))

(define (ln-count-tokens [buf : (&mut buf (Slice u8))] [n : i64]) : i64
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

(define (ln-fill-tokens
  [buf : (&mut buf (Slice u8))]
  [n : i64]
  [tokens : (&mut tokens storage.I64Buffer)]) : unit
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
                  (ln-set! tokens count value)
                  (set! count (+ count 1))
                  (set! value 0)
                  (set! inside false))))
            (set! i (+ i 1)))))
      (when
        inside
        (begin
          (ln-set! tokens count value)
          (set! count (+ count 1))))
      unit)))

;; ---- the dataflow ----
;; `compiler-live-successor-live-out-graph-loop` then the phi-out union of
;; `compiler-live-recompute-block-graph-ep`, into a scratch word slice.
(define (ln-live-out-into!
  [scratch : (&mut scratch storage.I64Buffer)]
  [words : i64]
  [g : i64]
  [succ-start : (&mut succ-start storage.I64Buffer)]
  [succ-items : (&mut succ-items storage.I64Buffer)]
  [live-in : (&mut live-in storage.I64Buffer)]
  [word-base : i64]
  [block-base : i64]
  [phi-out : (&mut phi-out storage.I64Buffer)]
  [with-phi-out : bool]) : unit
  (let
    [k : i64 0]
    [stop : i64 (ln-ref succ-start (+ g 1))]
    [slot : i64 (ln-ref succ-start g)]
    (begin
      (while (< k words)
        (begin
          (ln-set! scratch k 0)
          (set! k (+ k 1))))
      (while (< slot stop)
        (let
          [succ : i64 (ln-ref succ-items slot)]
          [succ-base : i64 (+ word-base (* (- succ block-base) words))]
          [i : i64 0]
          (begin
            (while (< i words)
              (begin
                (ln-set!
                  scratch
                  i
                  (bit-or (ln-ref scratch i) (ln-ref live-in (+ succ-base i))))
                (set! i (+ i 1))))
            (set! slot (+ slot 1)))))
      (when
        with-phi-out
        (let
          [self-base : i64 (+ word-base (* (- g block-base) words))]
          [i : i64 0]
          (while (< i words)
            (begin
              (ln-set!
                scratch
                i
                (bit-or (ln-ref scratch i) (ln-ref phi-out (+ self-base i))))
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
  [succ-start : (&mut succ-start storage.I64Buffer)]
  [succ-items : (&mut succ-items storage.I64Buffer)]
  [uses : (&mut uses storage.I64Buffer)]
  [defs : (&mut defs storage.I64Buffer)]
  [phi-out : (&mut phi-out storage.I64Buffer)]
  [live-in : (&mut live-in storage.I64Buffer)]
  [live-out : (&mut live-out storage.I64Buffer)]
  [scratch-out : (&mut scratch-out storage.I64Buffer)]
  [scratch-in : (&mut scratch-in storage.I64Buffer)]
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
          (ln-set!
            scratch-in
            i
            (bit-or
              (ln-ref uses (+ self-base i))
              (bit-and
                (ln-ref scratch-out i)
                (bit-xor (ln-ref defs (+ self-base i)) -1))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (and (< i words) (not changed))
        (begin
          (when
            (or
              (!= (ln-ref scratch-in i) (ln-ref live-in (+ self-base i)))
              (!= (ln-ref scratch-out i) (ln-ref live-out (+ self-base i))))
            (set! changed true))
          (set! i (+ i 1))))
      (when
        changed
        (let
          [k : i64 0]
          (while (< k words)
            (begin
              (ln-set! live-in (+ self-base k) (ln-ref scratch-in k))
              (ln-set! live-out (+ self-base k) (ln-ref scratch-out k))
              (set! k (+ k 1))))))
      changed)))

;; `compiler-live-fixpoint` / `compiler-live-fixpoint-ep` over one function.
(define (ln-fixpoint!
  [block-base : i64]
  [blocks : i64]
  [words : i64]
  [word-base : i64]
  [succ-start : (&mut succ-start storage.I64Buffer)]
  [succ-items : (&mut succ-items storage.I64Buffer)]
  [pred-start : (&mut pred-start storage.I64Buffer)]
  [pred-items : (&mut pred-items storage.I64Buffer)]
  [uses : (&mut uses storage.I64Buffer)]
  [defs : (&mut defs storage.I64Buffer)]
  [phi-out : (&mut phi-out storage.I64Buffer)]
  [live-in : (&mut live-in storage.I64Buffer)]
  [live-out : (&mut live-out storage.I64Buffer)]
  [pending : (&mut pending storage.I64Buffer)]
  [scratch-out : (&mut scratch-out storage.I64Buffer)]
  [scratch-in : (&mut scratch-in storage.I64Buffer)]
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
            (ln-set! pending (+ block-base b) 1)
            (while (< k words)
              (begin
                (ln-set! live-in (+ self-base k) 0)
                (ln-set! live-out (+ self-base k) 0)
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
                  (= (ln-ref pending (+ block-base i)) 1)
                  (begin
                    (ln-set! pending (+ block-base i) 0)
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
                  [slot : i64 (ln-ref pred-start g)]
                  [stop : i64 (ln-ref pred-start (+ g 1))]
                  (while (< slot stop)
                    (begin
                      (ln-set! pending (ln-ref pred-items slot) 1)
                      (set! slot (+ slot 1))))))))))
      unit)))

;; `compiler-live-set-trim-length` then `compiler-live-set-count` over the
;; trimmed prefix. The compiler's `compiler-live-set-word-count-bits` tests all
;; thirty-two bit positions of every word; this counts by clearing the lowest
;; set bit instead, so the checksum costs work proportional to the live-in sets
;; rather than to the universe. Same value, and it keeps this row a measurement
;; of the fixpoint: with the compiler's per-bit spelling the fold alone is 78%
;; of the TypeLisp row.
(define (ln-set-count
  [words-array : (&mut words-array storage.I64Buffer)]
  [base : i64]
  [words : i64]) : i64
  (let
    [n : i64 words]
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (and (> n 0) (= (ln-ref words-array (+ base (- n 1))) 0))
        (set! n (- n 1)))
      (while (< i n)
        (let
          [bits : i64 (ln-ref words-array (+ base i))]
          (begin
            (while (!= bits 0)
              (begin
                (set! bits (bit-and bits (- bits 1)))
                (set! count (+ count 1))))
            (set! i (+ i 1)))))
      count)))

(define (ln-fold-live-in
  [live-in : (&mut live-in storage.I64Buffer)]
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
    [source : String (byte_buf.to-string (io.read-file path))]
    [text (storage.string-to-u8-vec source)]
    [n : i64 (storage.u8-len (& text))]
    [functions : i64 0]
    [total-blocks : i64 0]
    [total-words : i64 0]
    [total-succ : i64 0]
    [max-words : i64 1]
    [p : i64 0]
    [text-slots : (&mut text (Slice u8)) (storage.u8-view-mut (&mut text))]
    [token-count : i64 (ln-count-tokens text-slots n)]
    [tokens (storage.zero-i64-vec (+ token-count 1))]
    (begin
      (ln-fill-tokens text-slots n (&mut tokens))
      ;; Sizing pass over the token stream.
      (set! p 1)
      (set! functions (ln-owner-ref tokens p))
      (set! p (+ p 1))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [vars : i64 (ln-owner-ref tokens p)]
            [blocks : i64 (ln-owner-ref tokens (+ p 1))]
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
                        [c : i64 (ln-owner-ref tokens p)]
                        (begin
                          (when (= k 0) (set! total-succ (+ total-succ c)))
                          (set! p (+ p 1 c))
                          (set! k (+ k 1)))))
                    (set! b (+ b 1)))))
              (set! f (+ f 1))))))
      (let
        [fn-block-base (storage.zero-i64-vec (+ functions 1))]
        [fn-word-base (storage.zero-i64-vec (+ functions 1))]
        [fn-blocks (storage.zero-i64-vec (+ functions 1))]
        [fn-words (storage.zero-i64-vec (+ functions 1))]
        [succ-start (storage.zero-i64-vec (+ total-blocks 1))]
        [succ-items (storage.zero-i64-vec (+ total-succ 1))]
        [pred-start (storage.zero-i64-vec (+ total-blocks 2))]
        [pred-items (storage.zero-i64-vec (+ total-succ 1))]
        [pred-cursor (storage.zero-i64-vec (+ total-blocks 1))]
        [uses (storage.zero-i64-vec (+ total-words 1))]
        [uses-nophi (storage.zero-i64-vec (+ total-words 1))]
        [defs (storage.zero-i64-vec (+ total-words 1))]
        [phi-out (storage.zero-i64-vec (+ total-words 1))]
        [live-in (storage.zero-i64-vec (+ total-words 1))]
        [live-out (storage.zero-i64-vec (+ total-words 1))]
        [pending (storage.zero-i64-vec (+ total-blocks 1))]
        [scratch-out (storage.zero-i64-vec (+ max-words 1))]
        [scratch-in (storage.zero-i64-vec (+ max-words 1))]
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
                [vars : i64 (ln-owner-ref tokens p)]
                [blocks : i64 (ln-owner-ref tokens (+ p 1))]
                [words : i64 (ln-words-for vars)]
                [b : i64 0]
                (begin
                  (set! p (+ p 2))
                  (ln-owner-set! fn-block-base f block-base)
                  (ln-owner-set! fn-word-base f word-base)
                  (ln-owner-set! fn-blocks f blocks)
                  (ln-owner-set! fn-words f words)
                  (while (< b blocks)
                    (let
                      [g : i64 (+ block-base b)]
                      [self-base : i64 (+ word-base (* b words))]
                      [count : i64 0]
                      [j : i64 0]
                      (begin
                        (ln-owner-set! succ-start g succ-cursor)
                        (set! count (ln-owner-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-owner-set!
                              succ-items
                              succ-cursor
                              (+ block-base (ln-owner-ref tokens p)))
                            (set! succ-cursor (+ succ-cursor 1))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (ln-owner-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit!
                              (ln-owner-slice uses)
                              self-base
                              (ln-owner-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (ln-owner-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit!
                              (ln-owner-slice uses-nophi)
                              self-base
                              (ln-owner-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (ln-owner-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit!
                              (ln-owner-slice defs)
                              self-base
                              (ln-owner-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! count (ln-owner-ref tokens p))
                        (set! p (+ p 1))
                        (set! j 0)
                        (while (< j count)
                          (begin
                            (ln-set-bit!
                              (ln-owner-slice phi-out)
                              self-base
                              (ln-owner-ref tokens p))
                            (set! p (+ p 1))
                            (set! j (+ j 1))))
                        (set! b (+ b 1)))))
                  (set! block-base (+ block-base blocks))
                  (set! word-base (+ word-base (* blocks words)))
                  (set! f (+ f 1))))))
          (ln-owner-set! succ-start total-blocks succ-cursor)
          ;; `compiler-live-predecessors-build`: count, then fill.
          (let
            [i : i64 0]
            (begin
              (while (< i succ-cursor)
                (let
                  [target : i64 (ln-owner-ref succ-items i)]
                  (begin
                    (ln-owner-set!
                      pred-cursor
                      target
                      (+ (ln-owner-ref pred-cursor target) 1))
                    (set! i (+ i 1)))))
              (set! i 0)
              (let
                [running : i64 0]
                (begin
                  (while (< i total-blocks)
                    (begin
                      (ln-owner-set! pred-start i running)
                      (set! running (+ running (ln-owner-ref pred-cursor i)))
                      (ln-owner-set! pred-cursor i (ln-owner-ref pred-start i))
                      (set! i (+ i 1))))
                  (ln-owner-set! pred-start total-blocks running)))
              (set! i 0)
              (while (< i total-blocks)
                (let
                  [slot : i64 (ln-owner-ref succ-start i)]
                  [stop : i64 (ln-owner-ref succ-start (+ i 1))]
                  (begin
                    (while (< slot stop)
                      (let
                        [target : i64 (ln-owner-ref succ-items slot)]
                        [at : i64 (ln-owner-ref pred-cursor target)]
                        (begin
                          (ln-owner-set! pred-items at i)
                          (ln-owner-set! pred-cursor target (+ at 1))
                          (set! slot (+ slot 1)))))
                    (set! i (+ i 1)))))))
          (while (< round rounds)
            (let
              [f : i64 0]
              (begin
                (while (< f functions)
                  (let
                    [base : i64 (ln-owner-ref fn-block-base f)]
                    [blocks : i64 (ln-owner-ref fn-blocks f)]
                    [words : i64 (ln-owner-ref fn-words f)]
                    [wbase : i64 (ln-owner-ref fn-word-base f)]
                    (begin
                      ;; `compiler-live-analyze-function`: the ordinary pass.
                      (storage.fixpoint!
                        base
                        blocks
                        words
                        wbase
                        (ln-owner-slice succ-start)
                        (ln-owner-slice succ-items)
                        (ln-owner-slice pred-start)
                        (ln-owner-slice pred-items)
                        (ln-owner-slice uses)
                        (ln-owner-slice defs)
                        (ln-owner-slice phi-out)
                        (ln-owner-slice live-in)
                        (ln-owner-slice live-out)
                        (ln-owner-slice pending)
                        (ln-owner-slice scratch-out)
                        (ln-owner-slice scratch-in)
                        false)
                      (set!
                        acc
                        (ln-fold-live-in
                          (ln-owner-slice live-in)
                          wbase
                          blocks
                          words
                          acc))
                      ;; `compiler-live-analyze-blocks-edge-precise`.
                      (storage.fixpoint!
                        base
                        blocks
                        words
                        wbase
                        (ln-owner-slice succ-start)
                        (ln-owner-slice succ-items)
                        (ln-owner-slice pred-start)
                        (ln-owner-slice pred-items)
                        (ln-owner-slice uses-nophi)
                        (ln-owner-slice defs)
                        (ln-owner-slice phi-out)
                        (ln-owner-slice live-in)
                        (ln-owner-slice live-out)
                        (ln-owner-slice pending)
                        (ln-owner-slice scratch-out)
                        (ln-owner-slice scratch-in)
                        true)
                      (set!
                        acc
                        (ln-fold-live-in
                          (ln-owner-slice live-in)
                          wbase
                          blocks
                          words
                          acc))
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