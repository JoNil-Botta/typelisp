(import stdlib.io)
(import stdlib.string)

;; FORCING TEST for the unsigned range-check merge (A3).
;;
;; `(and (>= i 0) (< i n))` lowers to a short-circuit diamond -- two compares
;; and two conditional branches -- for a question one unsigned compare answers,
;; because `0 <= i < n` is exactly `i <u n` whenever `n` is non-negative.
;; `bounds_dom` merges them into `lt (cast i : u64), (cast n : u64)`, which the
;; backend selects `jb`/`jae` for.
;;
;; Three shapes, one per source of the non-negativity the fold needs:
;;
;;   `literal-window` has a literal bound, the cheapest source. Before the merge
;;   its body holds a sign test (`testq %rX, %rX` with a signed `jl`) AND a
;;   signed `cmpq $16`; after it, one `cmpq $16` with an unsigned `jae` and no
;;   sign test at all.
;;
;;   `paired-window` is the straight-line `and`-chain: the second guard's bound
;;   is the first guard's, and `0 <= i` with `i < n` proves `0 < n` for it
;;   through the fact chain -- the same reading clang's `computeKnownBits` makes
;;   of the dominating conditions. Its FIRST guard cannot merge (nothing bounds
;;   `n` yet) and its second must, so the function pins both verdicts at once.
;;
;;   `global-window` is the cached-length idiom, and the one that needs the
;;   whole-program table (`opt-nonneg-globals-build`): `rm-len` is a module-level
;;   `i64` whose only store takes a String's length word, so every read of it is
;;   non-negative and the guard against it merges. No dominating comparison in
;;   this function proves anything about `rm-len`.
;;
;; scripts/verify-asm-shape-gates.sh pins those shapes; the exit code below pins
;; the semantics, including that both out-of-range directions still answer -1 --
;; a merge that lost the lower bound would accept a negative index.
(define rm-text : String
  "abcdefghij")
(define rm-len : i64
  0)

(define (literal-window [i : i64]) : i64
  (if (and (>= i 0) (< i 16))
    (* i 2)
    -1))

(define (paired-window [n : i64] [i : i64] [j : i64]) : i64
  (if (and (>= i 0) (< i n))
    (if (and (>= j 0) (< j n))
      (+ i j)
      -1)
    -1))

(define (global-window [i : i64]) : i64
  (if (and (>= i 0) (< i rm-len))
    (* i 7)
    -1))

(define (main) : i64
  (let
    ;; The program name is argument 0, so `base` is 0 with no arguments.
    [base : i64 (- (io.arg-count) 1)]
    [acc : i64 0]
    (begin
      (set! rm-len (string.string-length rm-text))
      (set! acc (+ acc (literal-window (+ base 3))))
      (set! acc (+ acc (literal-window (+ base 15))))
      (set! acc (+ acc (literal-window (+ base 16))))
      (set! acc (+ acc (literal-window (- base 1))))
      (set! acc (+ acc (literal-window (- base 4096))))
      ;; 6 + 30 - 1 - 1 - 1 = 33
      (set! acc (+ acc (paired-window (+ base 8) (+ base 2) (+ base 5))))
      (set! acc (+ acc (paired-window (+ base 8) (+ base 2) (+ base 8))))
      (set! acc (+ acc (paired-window (+ base 8) (- base 1) (+ base 5))))
      (set! acc (+ acc (paired-window (- base 1) (+ base 2) (+ base 5))))
      ;; 7 - 1 - 1 - 1 = 4; running total 37
      (set! acc (+ acc (global-window (+ base 4))))
      (set! acc (+ acc (global-window (+ base 9))))
      (set! acc (+ acc (global-window (+ base 10))))
      (set! acc (+ acc (global-window (- base 1))))
      ;; rm-len is 10: 28 + 63 - 1 - 1 = 89; total 126
      (if (= acc 126)
        42
        1))))