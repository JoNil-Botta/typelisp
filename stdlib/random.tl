;# Deterministic pseudo-random helpers for TypeLisp tools (#882).
;#
;# This module provides a small seeded, deterministic, non-cryptographic
;# generator plus weighted index selection for selfhost tooling. It does not
;# read host entropy; callers choose the seed, commonly from a literal in
;# tests or from argv in local tools that want variation.
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
;# `RandomState`, draw results, and weight-list cons nodes are ordinary
;# aggregates allocated in the active arena when constructed. The generator is
;# MINSTD/Park-Miller with Schrage constants, so it avoids signed `i64`
;# overflow and remains portable across current TypeLisp targets.
;: Pseudo-random generator state. Valid normalized seeds are in `1..2147483647`.
(import "io.tl")

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

;: Linear list of non-negative weights.
(defenum RandomWeightList
  (RandomWeightNil)
  (RandomWeightCons i64 RandomWeightList))

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
  (RandomWeightCons weight rest))

;: Return true when a weight list has no entries.
(define (random-weight-list-empty? [weights : RandomWeightList]) : bool
  (match weights
    [(RandomWeightNil) true]
    [(RandomWeightCons _ _) false]))

;: Accumulate and validate non-negative weights.
(define (random-weight-list-total-nonempty
  [weights : RandomWeightList]
  [acc : i64]) : RandomWeightTotalResult
  (match weights
    [(RandomWeightNil) (OkRandomWeightTotal acc)]
    [(RandomWeightCons weight rest)
      (if (< weight 0)
        (ErrRandomWeightTotal "random: weight must not be negative")
        (random-weight-list-total-nonempty rest (+ acc weight)))]))

;: Return the total weight, rejecting empty lists and negative weights.
(define (random-weight-list-total [weights : RandomWeightList]) : RandomWeightTotalResult
  (if (random-weight-list-empty? weights)
    (ErrRandomWeightTotal "random: weight list must not be empty")
    (random-weight-list-total-nonempty weights 0)))

;: Pick the first index whose cumulative positive weight contains `target`.
(define (random-weighted-index-scan
  [weights : RandomWeightList]
  [target : i64]
  [index : i64]) : i64
  (match weights
    [(RandomWeightNil) -1]
    [(RandomWeightCons weight rest)
      (if (<= weight 0)
        (random-weighted-index-scan rest target (+ index 1))
        (if (< target weight)
          index
          (random-weighted-index-scan rest (- target weight) (+ index 1))))]))

;: Choose an index from `weights`, skipping zero weights.
;:
;: The result index is zero-based in list order. Empty lists, negative weights,
;: and lists whose total weight is zero return structured errors.
(define (random-weighted-index
  [state : RandomState]
  [weights : RandomWeightList]) : RandomWeightedIndexResult
  (match (random-weight-list-total weights)
    [(ErrRandomWeightTotal message) (ErrRandomWeightedIndex message)]
    [(OkRandomWeightTotal total)
      (if (<= total 0)
        (ErrRandomWeightedIndex "random: weight total must be positive")
        (match (random-bounded state total)
          [(OkRandomBounded next-state target)
            (OkRandomWeightedIndex
              next-state
              (random-weighted-index-scan weights target 0))]
          [(ErrRandomBounded message) (ErrRandomWeightedIndex message)]))]))

;: Backend runtime hook: read host entropy and return a structured result.
(extern tl_random_system_seed : (-> ResultSystemSeed))

;: Return a system-provided random seed, or a diagnostic when entropy is
;: unavailable. The seed is normalized to the valid MINSTD range.
(define (random-system-seed) : ResultSystemSeed
  (match (tl_random_system_seed)
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