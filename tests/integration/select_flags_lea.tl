(import stdlib.io)
(import compiler_owned_view as owned_view)

;; FORCING TEST for T2-4 (SS-P5 / VG-P-B), pinned by
;; scripts/verify-asm-shape-gates.sh:check_select_flags_lea. Two rules:
;;
;;   sfl-*-scan  -- a scalar Select whose mask is the comparison IMMEDIATELY in
;;                  front of it and is read nowhere else. The comparison's own
;;                  flags must drive one `cmov<cc>`, so the whole join costs
;;                  `mov ; cmp ; cmov` plus the allocator's spill store -- four
;;                  instructions. Before the change it cost seven: the mask was
;;                  materialised (`mov ; cmp ; setcc ; movzbq`) and then RE-
;;                  tested (`mov ; testq ; cmovne`). The three scans pin the
;;                  condition-code table on both signednesses and both
;;                  polarities: signed min (`cmovl`), signed max (`cmovg`) and
;;                  unsigned min (`cmovb`).
;;   sfl-copy    -- a byte-copy loop whose BCE fast path computes
;;                  `gep(data, start)` with a SPILLED base, which routes the
;;                  address through the staged emitter. Its index is
;;                  register-homed, and `addq idx, base` only READS the index,
;;                  so no staging copy of it is owed. Before the change the
;;                  emitter copied it unconditionally and, with the scratch
;;                  register occupied, paid an emergency save/restore for the
;;                  copy: `movq %r9, %xmm4 ; movq %rcx, %r9 ; addq %r9, %rax ;
;;                  movq %xmm4, %r9` where one `addq %rcx, %rax` does.
;;
;; main exercises every path at runtime, at all four gep scales and both cmov
;; polarities: a wrong condition code or an index read out of a clobbered
;; register shows up as a wrong answer.
(define (sfl-min-scan [xs : (__tl_dyn-array i64)] [n : i64] [cap : i64])
  (:export-symbol "tl_sfl_min_scan") : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [x : i64 (array-ref xs i)]
          [m : i64
            (if (< x cap)
              x
              cap)]
          (begin
            (set! acc (+ acc m))
            (set! i (+ i 1)))))
      acc)))

(define (sfl-max-scan [xs : (__tl_dyn-array i64)] [n : i64] [floor : i64])
  (:export-symbol "tl_sfl_max_scan") : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [x : i64 (array-ref xs i)]
          [m : i64
            (if (> x floor)
              x
              floor)]
          (begin
            (set! acc (+ acc m))
            (set! i (+ i 1)))))
      acc)))

(define (sfl-umin-scan [xs : (__tl_dyn-array u64)] [n : i64] [cap : u64])
  (:export-symbol "tl_sfl_umin_scan") : u64
  (let
    [acc : u64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [x : u64 (array-ref xs i)]
          [m : u64
            (if (< x cap)
              x
              cap)]
          (begin
            (set! acc (+ acc m))
            (set! i (+ i 1)))))
      acc)))

(define (sfl-copy
  [dst : (__tl_dyn-array u8)]
  [dst-start : i64]
  [src : (__tl_dyn-array u8)]
  [src-start : i64]
  [count : i64])
  (:export-symbol "tl_sfl_copy") : unit
  (let
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref dst (+ dst-start index))
            (array-ref src (+ src-start index)))
          (set! index (+ index 1))))
      unit)))

;; Variable-index geps at all four scales the SIB byte can spell -- the ones the
;; staged emitter now composes straight off a register-homed index.
(define (sfl-scales
  [b : (__tl_dyn-array u8)]
  [h : (__tl_dyn-array i16)]
  [w : (__tl_dyn-array i32)]
  [q : (__tl_dyn-array i64)]
  [n : i64]
  [k : i64])
  (:export-symbol "tl_sfl_scales") : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [j : i64 (+ i k)]
          (begin
            (set! acc (+ acc (cast (array-ref b j) : i64)))
            (set! acc (+ acc (cast (array-ref h j) : i64)))
            (set! acc (+ acc (cast (array-ref w j) : i64)))
            (set! acc (+ acc (array-ref q j)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    ;; (io.arg-count) = 1 without args; it blocks constant folding.
    [v : i64 (io.arg-count)]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [us : (__tl_dyn-array u64) (__tl_make-array u64 4)]
    [_x0 : unit (set! (array-ref xs 0) 1)]
    [_x1 : unit (set! (array-ref xs 1) 9)]
    [_x2 : unit (set! (array-ref xs 2) 3)]
    [_x3 : unit (set! (array-ref xs 3) 7)]
    [_u0 : unit (set! (array-ref us 0) (cast 1 : u64))]
    [_u1 : unit (set! (array-ref us 1) (cast 9 : u64))]
    [_u2 : unit (set! (array-ref us 2) (cast 3 : u64))]
    [_u3 : unit (set! (array-ref us 3) (cast 7 : u64))]
    ;; min(1,5) + min(9,5) + min(3,5) + min(7,5) = 1 + 5 + 3 + 5 = 14
    [mn : i64
      (sfl-min-scan (owned_view.compiler-owned-shared-view xs) (+ v 3) 5)]
    ;; max(1,5) + max(9,5) + max(3,5) + max(7,5) = 5 + 9 + 5 + 7 = 26
    [mx : i64
      (sfl-max-scan (owned_view.compiler-owned-shared-view xs) (+ v 3) 5)]
    [umn : u64 (sfl-umin-scan us (+ v 3) (cast 5 : u64))]
    [src : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [dst : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [_s0 : unit (set! (array-ref src 2) (cast 11 : u8))]
    [_s1 : unit (set! (array-ref src 3) (cast 22 : u8))]
    [_s2 : unit (set! (array-ref src 4) (cast 33 : u8))]
    [_copy : unit
      (sfl-copy
        (owned_view.compiler-owned-shared-view dst)
        (+ v 0)
        src
        (+ v 1)
        (+ v 2))]
    ;; dst[1] = src[2] = 11, dst[2] = src[3] = 22, dst[3] = src[4] = 33
    [copied : i64
      (+
        (cast (array-ref dst 1) : i64)
        (+ (cast (array-ref dst 2) : i64) (cast (array-ref dst 3) : i64)))]
    [b : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [h : (__tl_dyn-array i16) (__tl_make-array i16 8)]
    [w : (__tl_dyn-array i32) (__tl_make-array i32 8)]
    [q : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [_b : unit (set! (array-ref b 2) (cast 3 : u8))]
    [_h : unit (set! (array-ref h 2) (cast 40 : i16))]
    [_w : unit (set! (array-ref w 2) (cast 500 : i32))]
    [_q : unit (set! (array-ref q 2) 6000)]
    ;; one iteration at j = 2: 3 + 40 + 500 + 6000 = 6543
    [scales : i64 (sfl-scales b h w q v (+ v 1))]
    (if (and
      (= mn 14)
      (= mx 26)
      (= umn (cast 14 : u64))
      (= copied 66)
      (= scales 6543))
      42
      1)))