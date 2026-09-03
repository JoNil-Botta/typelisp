;; FORCING TEST for CB-2b: a checked-tier CLAIM must not withdraw the cheap
;; tiers' inlines of another callee.
;;
;; Two callees share this program and belong to different tiers.
;;
;;   * `mix` is a four-site tiny leaf that the cheap, unmeasured bands take for
;;     free: one straight-line block of four arithmetic instructions, call-free
;;     and bounds-free, which the ordinary cost model admits at each of its four
;;     sites (twice inside `probe`'s loop, once in `checksum`, once in `main`).
;;     Nothing about it is the measured tier's business, and the measured tier is
;;     never even asked about it -- a site a band admits is never offered to the
;;     check.
;;   * `hash-words` is the intern kernel's shape -- a cyclic, call-free,
;;     bounds-carrying word loop -- called ONCE from `probe`'s ENTRY block.
;;     Every band refuses that site, and only the measured tier's re-plan, and
;;     only through CB-2's relaxed depth floor, can take it.
;;
;; So one compilation makes the measured tier claim a body in exactly the caller
;; whose loop holds the cheap tier's leaf. The claim must add an inline and take
;; nothing away: `probe` must come out with `hash-words`'s FNV seed and word
;; loop inside it AND with no call to `mix` anywhere, and `mix` must have no
;; out-of-line definition left at all -- all four of its sites inlined, exactly
;; as they are when the measured tier claims nothing.
;;
;; The exit code proves the values either way; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh.
(define (mix [a : i64] [b : i64]) : i64
  (bit-xor (+ (* a 3) b) (* b 5)))

(define (hash-words
  [data : (& d (__tl_dyn-array i64))]
  [start : i64]
  [len : i64]) : i64
  (let
    [h : i64 2166136261]
    [i : i64 start]
    (begin
      (while (< i (+ start len))
        (begin
          (set! h (bit-xor h (array-ref data i)))
          (set! h (* h 16777619))
          (set! i (+ i 1))))
      h)))

;; The hot caller: the hash at its entry, then a loop of its own holding two of
;; the tiny leaf's four sites.
(define (probe [data : (& d (__tl_dyn-array i64))] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (hash-words data start len)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! acc (+ acc (bit-and (mix h i) 1023)))
          (set! acc (+ acc (bit-and (mix i h) 511)))
          (set! h (+ h 7))
          (set! i (+ i 1))))
      acc)))

;; A cold second reference to the hash and to the caller, so no single-reference
;; band can claim either before the measured tier is asked; the leaf's third
;; site rides along.
(define (checksum [data : (& d (__tl_dyn-array i64))] [len : i64]) : i64
  (+ (bit-and (mix (hash-words data 0 len) len) 65535) (probe data 0 4)))

(define (main) : i64
  (let
    [data : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 32)
        (begin
          (set! (array-ref data i) (* (+ i 1) 2654435761))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 64)
        (begin
          (set! total (+ total (probe (& data) 0 16)))
          (set! i (+ i 1))))
      (unless (= total 427008) (return 1))
      (unless (= (checksum (& data) 8) 2443) (return 2))
      (unless (= (mix total 3) 1281036) (return 3))
      42)))