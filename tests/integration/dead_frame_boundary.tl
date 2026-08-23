(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for W1-frame (dead frame adjust + dead alignment pad for
;; boundary-only functions), pinned by scripts/verify-asm-shape-gates.sh:
;; check_dead_frame_boundary reads the Linux emission, and
;; check_dead_frame_boundary_win64 reads the same source compiled for Win64,
;; where the 32-byte shadow space every call-shaped instruction reserves keeps
;; the frame alive and the adjustment must therefore SURVIVE. Four shapes:
;;
;;   dfb-forward     -- its only call-shaped instruction is a TAIL call and it
;;                      names no frame slot. A tail `jmp` leaves through the
;;                      epilogue with the entry %rsp already restored, so it
;;                      needs neither a slot region nor an alignment pad: the
;;                      whole `subq`/`addq` pair must be gone.
;;   dfb-abort-only  -- callee-saved homes are pushed (an EVEN push run, so the
;;                      old unconditional pad applied) and the only `call` is
;;                      the never-taken `tl_oob_abort` edge. The abort handler
;;                      is a compiler-emitted `never` routine that prints
;;                      through raw syscalls, so it inherits no alignment duty:
;;                      the pushes stay, the pad goes.
;;   dfb-returning   -- makes an ordinary returning call, so its frame and its
;;                      alignment pad must BOTH survive untouched.
;;   main            -- exercises every path at runtime, including the
;;                      in-bounds arm of the abort-only function.
;;
;; Pre-change these emitted `subq $N, %rsp` / `addq $N, %rsp` in all three, so
;; the first two assertions are proven forcing.
;; Self-tail-recursive, so it becomes a loop and callers reach it by `jmp`.
;; Never inlined into the forwarder: opt-tailrec owns it first.
(define (dfb-sink [a : i64] [b : i64]) : i64
  (if (<= a 0)
    b
    (dfb-sink (- a 1) (+ b 1))))

;; Recursive on purpose so the leaf inliner cannot delete the call.
(define (dfb-probe [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (dfb-probe (- x 1)))))

;; (a) TAIL-CALL-ONLY, no frame slot: no stack adjustment at all.
(define (dfb-forward [a : i64]) : i64
  (dfb-sink a -4))

;; (b) ABORT-ONLY under an even callee-saved push run: the pushes stay, the
;; 8-byte alignment pad goes. Five values stay live across the whole loop so
;; the plan reaches for callee-saved homes; the trailing dynamic index plants
;; the bounds check whose cold arm is the only `call` in the body.
(define (dfb-abort-only [xs : (__tl_dyn-array i64)] [n : i64] [k : i64])
  ;; Exported so the standalone body survives even when the inliner absorbs it
  ;; at every call site: the shape gate reads this emitted function.
  (:export-symbol "tl_dfb_abort_only")
  : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [d : i64 4]
    [e : i64 5]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* a i)))
          (set! acc (+ acc (* b i)))
          (set! acc (+ acc (* c i)))
          (set! acc (+ acc (* d i)))
          (set! acc (+ acc (* e i)))
          (set! a (+ a 1))
          (set! b (+ b 2))
          (set! c (+ c 3))
          (set! d (+ d 4))
          (set! e (+ e 5))
          (set! i (+ i 1))))
      (+ acc (+ (array-ref xs k) (+ a (+ b (+ c (+ d e)))))))))

;; (c) A RETURNING call keeps the frame and the pad.
(define (dfb-returning [v : i64] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! acc (+ acc (dfb-probe i)))
          (set! acc (+ acc (* v i)))
          (set! acc (+ acc (* a i)))
          (set! acc (+ acc (* b i)))
          (set! acc (+ acc (* c i)))
          (set! a (+ a 1))
          (set! b (+ b 2))
          (set! c (+ c 3))
          (set! i (+ i 1))))
      (if (> rounds 1)
        (+ acc (dfb-returning v (- rounds 1)))
        (+ acc (+ a (+ b c)))))))

(define (main) : i64
  (let
    ;; (io.arg-count) = 1 without args; it blocks constant folding of all three.
    [v : i64 (io.arg-count)]
    [xs : (__tl_dyn-array i64) (array.make-array i64 4)]
    [_seed : unit (set! (array-ref xs 3) 11)]
    ;; dfb-sink(1, -4) = -3
    [f : i64 (dfb-forward v)]
    ;; At iteration i the five values are 1+i, 2+2i, 3+3i, 4+4i, 5+5i, so
    ;; acc grows by i*(15 + 15i).
    ;;   n = 5, k = 3: acc = 15*10 + 15*30 = 600; finals 6+12+18+24+30 = 90;
    ;;                 xs[3] = 11 -> 701
    ;;   n = 1, k = 1: acc = 0; finals 2+4+6+8+10 = 30; xs[1] = 0 -> 30
    [g : i64 (+ (dfb-abort-only xs (+ v 4) (+ v 2)) (dfb-abort-only xs v v))]
    ;; sum over i in 0..7 of i*(1 + v + a_i + b_i + c_i)
    ;;   = sum i*(2 + (1+i) + (2+2i) + (3+3i)) = sum 8i + 6i^2 = 224 + 840 = 1064
    ;; finals a = 9, b = 18, c = 27 -> 1064 + 54 = 1118
    [h : i64 (dfb-returning v 1)]
    (if (and (= f -3) (= g 731) (= h 1118))
      42
      1)))