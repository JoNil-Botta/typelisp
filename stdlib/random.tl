;# Deterministic pseudo-random helpers for TypeLisp tools (#882).
;#
;# This module provides a small seeded, deterministic, non-cryptographic
;# generator plus array/vector/list weighted index selection for selfhost
;# tooling. Deterministic draws do not read host entropy; callers choose the
;# seed, commonly from a literal in tests or from argv in local tools that want
;# variation. The optional `random-system-seed` wrapper reads a platform seed
;# through direct FFI.
;#
;# Usage: `(import "stdlib/random.tl")`
;#
;# ```typelisp
;# (import "stdlib/random.tl")
;# (define (main) : i64
;#   (match (random-bounded (random-seed 1) 10)
;#     [(OkRandomBounded _ value) value]
;#     [(ErrRandomBounded _) 0]))
;# ```
;#
;# `RandomState`, draw results, and compatibility weight-list cons nodes are
;# ordinary aggregates allocated in the active arena when constructed. Array and
;# `I64Vec` weighted-index helpers scan caller-owned storage directly. The
;# generator is MINSTD/Park-Miller with Schrage constants, so it avoids signed
;# `i64` overflow and remains portable across current TypeLisp targets.
(import "io.tl")

(import "vector.tl")

;: Pseudo-random generator state. Valid normalized seeds are in `1..2147483647`.
(defstruct RandomState
  (seed i64))

;: Result of one unbounded draw: next state plus generated positive `i64`.
(defstruct RandomDraw
  (state RandomState)
  (value i64))

;: Return the normalized seed stored in `state`.
(define (random-state-seed [state : RandomState]) : i64
  (struct-get state seed))

;: Return the next state from a draw result.
(define (random-draw-state [draw : RandomDraw]) : RandomState
  (struct-get draw state))

;: Return the generated value from a draw result.
(define (random-draw-value [draw : RandomDraw]) : i64
  (struct-get draw value))

;: Recoverable bounded draw result.
(defenum RandomBoundedResult
  (OkRandomBounded RandomState i64)
  (ErrRandomBounded String))

;: Error enumeration for system entropy failures.
(defenum RandomSystemSeedError
  (RandomSystemSeedUnavailable String))

;: Result of reading OS entropy for a seed.
(defenum ResultSystemSeed
  (OkSystemSeed i64)
  (ErrSystemSeed RandomSystemSeedError))

;: Linux `getrandom` via the `getrandom` syscall (number 318), used by
;: `random-system-seed`. Returns the byte count or a negative status.
(cfg
  (not windows)
  (define (random-linux-syscall-getrandom
    [buf : (MutPtr u8)]
    [len : i64]
    [flags : i64]) : i64
    (io-linux-syscall-status
      (unsafe
        (syscall
          318
          (io-linux-ptr-arg
            (unsafe
              (ptr-cast buf : (Ptr u8))))
          len
          flags)))))

;: Windows kernel32 `QueryPerformanceCounter` binding used for seed variation.
(cfg
  windows
  (extern (random-windows-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))

;: Windows kernel32 `GetSystemTimeAsFileTime` binding used for seed variation.
(cfg
  windows
  (extern (random-windows-get-system-time-as-file-time [arg0 : (MutPtr i64)]) : unit (:symbol "GetSystemTimeAsFileTime")))

;: Windows kernel32 `GetCurrentProcessId` binding used for seed variation.
(cfg
  windows
  (extern (random-windows-get-current-process-id) : u32 (:symbol "GetCurrentProcessId")))

;: Windows kernel32 `GetCurrentThreadId` binding used for seed variation.
(cfg
  windows
  (extern (random-windows-get-current-thread-id) : u32 (:symbol "GetCurrentThreadId")))

;: Linear list of non-negative weights.
(defenum RandomWeightList
  (RandomWeightNil)
  (RandomWeightCons i64 (Box RandomWeightList)))

;: Recoverable weighted-index result.
(defenum RandomWeightedIndexResult
  (OkRandomWeightedIndex RandomState i64)
  (ErrRandomWeightedIndex String))

;: Internal recoverable total for weight validation.
(defenum RandomWeightTotalResult
  (OkRandomWeightTotal i64)
  (ErrRandomWeightTotal String))

;: Return the MINSTD modulus.
(define (random-modulus) : i64
  2147483647)

;: Return the MINSTD multiplier.
(define (random-multiplier) : i64
  16807)

;: Return the Schrage quotient for MINSTD.
(define (random-schrage-q) : i64
  127773)

;: Return the Schrage remainder for MINSTD.
(define (random-schrage-r) : i64
  2836)

;: Normalize any caller seed to the valid MINSTD seed range.
(define (random-normalize-seed-value [seed : i64]) : i64
  (let
    [m : i64 (random-modulus)]
    [raw : i64 (% seed (random-modulus))]
    [positive : i64
      (if (< raw 0)
        (+ raw m)
        raw)]
    (if (= positive 0)
      1
      positive)))

;: Construct a normalized deterministic RNG state from `seed`.
(define (random-seed [seed : i64]) : RandomState
  (RandomState (random-normalize-seed-value seed)))

;: Advance `state` once and return the next state plus generated value.
(define (random-next [state : RandomState]) : RandomDraw
  (let
    [seed : i64 (random-normalize-seed-value (random-state-seed state))]
    [q : i64 (random-schrage-q)]
    [hi : i64 (/ seed q)]
    [lo : i64 (- seed (* hi q))]
    [test : i64 (- (* (random-multiplier) lo) (* (random-schrage-r) hi))]
    [next-seed : i64
      (if (> test 0)
        test
        (+ test (random-modulus)))]
    [next-state : RandomState (RandomState next-seed)]
    (RandomDraw next-state next-seed)))

;: Draw a value in `0 <= value < upper`, or return an error for invalid bounds.
(define (random-bounded [state : RandomState] [upper : i64]) : RandomBoundedResult
  (if (<= upper 0)
    (ErrRandomBounded "random: upper bound must be positive")
    (let
      [draw : RandomDraw (random-next state)]
      (OkRandomBounded
        (random-draw-state draw)
        (% (random-draw-value draw) upper)))))

;: Return an empty weight list.
(define (random-weight-list-empty) : RandomWeightList
  (RandomWeightNil))

;: Prepend `weight` to a weight list.
(define (random-weight-list-cons [weight : i64] [rest : RandomWeightList]) : RandomWeightList
  (RandomWeightCons weight (box rest)))

;: Return true when a weight list has no entries.
(define (random-weight-list-empty? [weights : RandomWeightList]) : bool
  (match weights
    [(RandomWeightNil) true]
    [(RandomWeightCons _ _) false]))

;: Accumulate and validate non-negative array weights in the prefix
;: `[0, count)`.
(define (random-weight-array-total-from
  [weights : (Array i64)]
  [count : i64]
  [index : i64]
  [acc : i64]) : RandomWeightTotalResult
  (if (>= index count)
    (OkRandomWeightTotal acc)
    (let
      [weight : i64 (array-ref weights index)]
      (if (< weight 0)
        (ErrRandomWeightTotal "random: weight must not be negative")
        (random-weight-array-total-from
          weights
          count
          (+ index 1)
          (+ acc weight))))))

;: Return the total weight for an array prefix, rejecting empty prefixes and
;: negative weights.
(define (random-weight-array-total-prefix
  [weights : (Array i64)]
  [count : i64]
  [empty-message : String]) : RandomWeightTotalResult
  (if (<= count 0)
    (ErrRandomWeightTotal empty-message)
    (random-weight-array-total-from weights count 0 0)))

;: Pick the first array-prefix index whose cumulative positive weight contains
;: `target`.
(define (random-weight-array-scan-from
  [weights : (Array i64)]
  [count : i64]
  [target : i64]
  [index : i64]) : i64
  (if (>= index count)
    -1
    (let
      [weight : i64 (array-ref weights index)]
      (if (<= weight 0)
        (random-weight-array-scan-from weights count target (+ index 1))
        (if (< target weight)
          index
          (random-weight-array-scan-from
            weights
            count
            (- target weight)
            (+ index 1)))))))

;: Choose an index from the first `count` entries of `weights`, skipping zero
;: weights. `empty-message` lets compatibility wrappers keep their historical
;: diagnostics while sharing the array-backed implementation.
(define (random-weighted-index-array-prefix
  [state : RandomState]
  [weights : (Array i64)]
  [count : i64]
  [empty-message : String]) : RandomWeightedIndexResult
  (match (random-weight-array-total-prefix weights count empty-message)
    [(ErrRandomWeightTotal message) (ErrRandomWeightedIndex message)]
    [(OkRandomWeightTotal total)
      (if (<= total 0)
        (ErrRandomWeightedIndex "random: weight total must be positive")
        (match (random-bounded state total)
          [(OkRandomBounded next-state target)
            (OkRandomWeightedIndex
              next-state
              (random-weight-array-scan-from weights count target 0))]
          [(ErrRandomBounded message) (ErrRandomWeightedIndex message)]))]))

;: Choose an index from `weights`, skipping zero weights.
;:
;: The result index is zero-based in array order. Empty arrays, negative
;: weights, and arrays whose total weight is zero return structured errors.
(define (random-weighted-index-array
  [state : RandomState]
  [weights : (Array i64)]) : RandomWeightedIndexResult
  (random-weighted-index-array-prefix
    state
    weights
    (array-length weights)
    "random: weight array must not be empty"))

;: Choose an index from the live prefix of `weights`, skipping zero weights.
;:
;: The result index is zero-based in vector order. Empty vectors, negative
;: weights, and vectors whose total weight is zero return structured errors.
(define (random-weighted-index-vec [state : RandomState] [weights : I64Vec]) : RandomWeightedIndexResult
  (random-weighted-index-array-prefix
    state
    (i64-vec-slots weights)
    (i64-vec-len weights)
    "random: weight vector must not be empty"))

;: Count weight-list entries.
(define (random-weight-list-count-from [weights : RandomWeightList] [acc : i64]) : i64
  (match weights
    [(RandomWeightNil) acc]
    [(RandomWeightCons _ rest)
      (random-weight-list-count-from (box-get rest) (+ acc 1))]))

;: Copy a weight list into `out` starting at `index`.
(define (random-weight-list-fill-array
  [out : (Array i64)]
  [weights : RandomWeightList]
  [index : i64]) : unit
  (match weights
    [(RandomWeightNil) unit]
    [(RandomWeightCons weight rest)
      (begin
        (array-set! out index weight)
        (random-weight-list-fill-array out (box-get rest) (+ index 1)))]))

;: Return a fresh array containing the weight list in list order.
(define (random-weight-list-to-array [weights : RandomWeightList]) : (Array i64)
  (let
    [count : i64 (random-weight-list-count-from weights 0)]
    [out : (Array i64) (make-array i64 count)]
    (begin
      (random-weight-list-fill-array out weights 0)
      out)))

;: Return the total weight, rejecting empty lists and negative weights.
(define (random-weight-list-total [weights : RandomWeightList]) : RandomWeightTotalResult
  (if (random-weight-list-empty? weights)
    (ErrRandomWeightTotal "random: weight list must not be empty")
    (let
      [array-weights : (Array i64) (random-weight-list-to-array weights)]
      (random-weight-array-total-prefix
        array-weights
        (array-length array-weights)
        "random: weight list must not be empty"))))

;: Choose an index from `weights`, skipping zero weights.
;:
;: The result index is zero-based in list order. Empty lists, negative weights,
;: and lists whose total weight is zero return structured errors.
(define (random-weighted-index
  [state : RandomState]
  [weights : RandomWeightList]) : RandomWeightedIndexResult
  (if (random-weight-list-empty? weights)
    (ErrRandomWeightedIndex "random: weight list must not be empty")
    (let
      [array-weights : (Array i64) (random-weight-list-to-array weights)]
      (random-weighted-index-array-prefix
        state
        array-weights
        (array-length array-weights)
        "random: weight list must not be empty"))))

;: Return the shared system-seed failure result.
(define (random-system-seed-unavailable) : ResultSystemSeed
  (ErrSystemSeed
    (RandomSystemSeedUnavailable "random: system entropy unavailable")))

;: Read a Linux system seed through `getrandom`.
(cfg
  (not windows)
  (define (random-linux-system-seed) : ResultSystemSeed
    (let
      [seed : (Array i64) (make-array i64 1)]
      [read-count : i64
        (random-linux-syscall-getrandom
          (unsafe
            (ptr-cast (array-data seed) : (MutPtr u8)))
          8
          0)]
      (if (= read-count 8)
        (OkSystemSeed (array-ref seed 0))
        (random-system-seed-unavailable)))))

;: Rotate a 64-bit value left by 17 bits.
(cfg
  windows
  (define (random-rotl64-17 [value : u64]) : u64
    (bit-or (shl value 17) (shr value 47))))

;: Finalize a mixed 64-bit seed using the SplitMix64 avalanche step from #2100.
(cfg
  windows
  (define (random-splitmix64-finalize [seed : u64]) : u64
    (let
      [z0 : u64 (+ seed (cast -7046029254386353131 : u64))]
      [z1 : u64 (bit-xor z0 (shr z0 30))]
      [z2 : u64 (* z1 (cast -4658895280553007687 : u64))]
      [z3 : u64 (bit-xor z2 (shr z2 27))]
      [z4 : u64 (* z3 (cast -7723592293110705685 : u64))]
      (bit-xor z4 (shr z4 31)))))

;: Build a Windows seed from kernel32 timing and process/thread identifiers.
(cfg
  windows
  (define (random-windows-system-seed) : ResultSystemSeed
    (let
      [counter : (Array i64) (make-array i64 1)]
      [file-time : (Array i64) (make-array i64 1)]
      [_counter-ok : i32
        (random-windows-query-performance-counter
          (unsafe
            (array-data counter)))]
      [_file-time-ok : unit
        (random-windows-get-system-time-as-file-time
          (unsafe
            (array-data file-time)))]
      [counter-seed : u64 (cast (array-ref counter 0) : u64)]
      [time-seed : u64 (random-rotl64-17 (cast (array-ref file-time 0) : u64))]
      [pid-seed : u64
        (shl (cast (random-windows-get-current-process-id) : u64) 32)]
      [thread-seed : u64 (cast (random-windows-get-current-thread-id) : u64)]
      [mixed : u64
        (bit-xor
          (bit-xor (bit-xor counter-seed time-seed) pid-seed)
          thread-seed)]
      (OkSystemSeed (cast (random-splitmix64-finalize mixed) : i64)))))

;: Return a system-provided random seed, or a diagnostic when entropy is
;: unavailable. The seed is normalized to the valid MINSTD range.
(define (random-system-seed) : ResultSystemSeed
  (match (cfg windows (random-windows-system-seed) (random-linux-system-seed))
    [(OkSystemSeed seed) (OkSystemSeed (random-normalize-seed-value seed))]
    [(ErrSystemSeed err) (ErrSystemSeed err)]))

;: Build a `RandomState` directly from host entropy, or panic when entropy is
;: unavailable. This is a convenience wrapper over `random-system-seed`.
(define (random-from-system) : RandomState
  (match (random-system-seed)
    [(OkSystemSeed seed) (random-seed seed)]
    [(ErrSystemSeed err)
      (panic
        (match err
          [(RandomSystemSeedUnavailable message) message]))]))