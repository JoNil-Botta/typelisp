(import stdlib.io)

;; FORCING TEST for T1-6 (a), abort-site half (pinned by
;; scripts/verify-asm-shape-gates.sh:check_red_zone_leaf and run end to end by
;; the red_zone_abort_* manifest cases). `rzt-probe` is a call-free leaf whose
;; only `call` is the never-taken `tl_oob_abort_at` edge and whose frame lives
;; in the red zone, so it carries NO stack adjustment: the located abort
;; splitter's `pushq`/`popq` argument staging runs at the entry %rsp, directly
;; above the live red-zone slots it reads its two reported values from. With
;; argc = 1 the index is in bounds and the checked answer comes back; with one
;; argument it is 4 against a length of 4 and the abort must render the site
;; and exit 134.
(define (rzt-probe
  [xs : (__tl_dyn-array i64)]
  [n : i64]
  [seed : i64]
  [idx : i64])
  (:export-symbol "tl_rzt_probe") : i64
  (let
    [v0 : i64 (+ seed 1)]
    [v1 : i64 (+ seed 2)]
    [v2 : i64 (+ seed 3)]
    [v3 : i64 (+ seed 4)]
    [v4 : i64 (+ seed 5)]
    [v5 : i64 (+ seed 6)]
    [v6 : i64 (+ seed 7)]
    [v7 : i64 (+ seed 8)]
    [v8 : i64 (+ seed 9)]
    [v9 : i64 (+ seed 10)]
    [v10 : i64 (+ seed 11)]
    [v11 : i64 (+ seed 12)]
    [acc : i64 1]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* v0 i)))
          (set! acc (+ acc (* v1 i)))
          (set! acc (+ acc (* v2 i)))
          (set! acc (+ acc (* v3 i)))
          (set! acc (+ acc (* v4 i)))
          (set! acc (+ acc (* v5 i)))
          (set! acc (+ acc (* v6 i)))
          (set! acc (+ acc (* v7 i)))
          (set! acc (+ acc (* v8 i)))
          (set! acc (+ acc (* v9 i)))
          (set! acc (+ acc (* v10 i)))
          (set! acc (+ acc (* v11 i)))
          (set! acc (+ acc (* (+ v0 v1) (+ v2 v3))))
          (set! acc (+ acc (* (+ v2 v3) (+ v4 v5))))
          (set! acc (+ acc (* (+ v4 v5) (+ v6 v7))))
          (set! v0 (+ v0 1))
          (set! v1 (+ v1 1))
          (set! v2 (+ v2 1))
          (set! v3 (+ v3 1))
          (set! v4 (+ v4 1))
          (set! v5 (+ v5 1))
          (set! v6 (+ v6 1))
          (set! v7 (+ v7 1))
          (set! v8 (+ v8 1))
          (set! v9 (+ v9 1))
          (set! v10 (+ v10 1))
          (set! v11 (+ v11 1))
          (set! i (+ i 1))))
      (+
        acc
        (+
          (array-ref xs idx)
          (+
            (+
              (+ (+ (+ (+ (+ (+ (+ (+ (+ v0 v1) v2) v3) v4) v5) v6) v7) v8) v9)
              v10)
            v11))))))

(define (main) : i64
  (let
    ;; (io.arg-count) is 1 without arguments and 2 with one.
    [v : i64 (io.arg-count)]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [_seed : unit (set! (array-ref xs 3) 11)]
    [r : i64 (rzt-probe xs (+ v 2) v (+ v 2))]
    (if (= r 2073)
      42
      1)))