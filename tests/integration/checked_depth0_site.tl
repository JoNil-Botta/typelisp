;; FORCING TEST for CB-2(c): a hot helper at a DEPTH-0 site of a hot caller.
;;
;; `hash-words` is the intern kernel's shape -- a cyclic, call-free,
;; bounds-carrying word loop of three parameters -- and `probe` calls it ONCE,
;; from its own entry block, before running its own loop. Every static band
;; refuses that site: the duplication band and the hot-loop-leaf band both want
;; the site to be inside a loop of the caller, the sole-call band wants an
;; acyclic callee at a call-free caller, and two references keep the
;; single-site absorption band out. The measured tier is the only door.
;;
;; The tier never opened it either: its site-depth clause refused a depth-0 site
;; outright rather than pricing it. The floor now stands down where all three of
;; its questions have answers -- the site is `probe`'s ENTRY block, so it runs
;; exactly once per invocation; `hash-words` is call-free, so the caller's leaf
;; frame is still winnable; and `main` reaches `probe` from inside a loop, so
;; the composite frequency clears one census weight -- and the verdict, a real
;; re-plan of the merged body, decides.
;;
;; The exit code proves the values either way; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh.
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

;; The caller: one straight-line call of the hash at its entry, then a loop of
;; its own that consumes the result.
(define (probe [data : (& d (__tl_dyn-array i64))] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (hash-words data start len)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! acc (+ acc (bit-and (bit-xor h i) 1023)))
          (set! h (+ h 7))
          (set! i (+ i 1))))
      acc)))

;; A cold second reference for each of them, so no single-reference band can
;; claim either before the measured tier is asked and both stay out of line for
;; the assembly-shape gate to read.
(define (checksum [data : (& d (__tl_dyn-array i64))] [len : i64]) : i64
  (+ (bit-and (hash-words data 0 len) 65535) (probe data 0 4)))

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
      (unless (= total 762880) (return 1))
      (unless (= (checksum (& data) 8) 22601) (return 2))
      42)))