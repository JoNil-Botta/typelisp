(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for T1-6 (a) (System V red-zone leaf frames), pinned by
;; scripts/verify-asm-shape-gates.sh:check_red_zone_leaf. Four shapes:
;;
;;   rzl-slots  -- a call-free leaf under enough register pressure to keep
;;                 several values in FRAME SLOTS, with a frame inside the
;;                 128-byte red zone. It must address those slots at NEGATIVE
;;                 displacements from %rsp and emit no `subq`/`addq $N, %rsp`.
;;   rzl-big    -- the same shape with a frame LARGER than the red zone: the
;;                 stack adjustment must survive.
;;   rzl-call   -- makes an ordinary returning call, so its frame and its
;;                 adjustment must both survive whatever their size.
;;   rzl-abort  -- a call-free leaf whose only `call` is the never-taken
;;                 `tl_oob_abort_at` edge, WITH live red-zone slots. The
;;                 located abort splitter stages its two reported values with
;;                 `pushq`/`popq`, i.e. it writes below %rsp -- exactly where
;;                 the red-zone slots live. The slot region is anchored below
;;                 that transient depth, so the pushes land above every slot
;;                 and the function still needs no stack adjustment.
;;
;; Pre-change all four emitted `subq $N, %rsp` / `addq $N, %rsp`, so the first
;; and the last assertion are proven forcing. main exercises every path at
;; runtime: a slot addressed at the wrong displacement, or an abort push
;; landing on a live slot, shows up as a wrong answer.
;; red_zone_abort_trap.tl runs the abort edge itself.
;; Recursive on purpose so the leaf inliner cannot delete the call.
(define (rzl-probe [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (rzl-probe (- x 1)))))

(define (rzl-slots [n : i64] [seed : i64])
  (:export-symbol "tl_rzl_slots") : i64
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
          (+
            (+ (+ (+ (+ (+ (+ (+ (+ (+ v0 v1) v2) v3) v4) v5) v6) v7) v8) v9)
            v10)
          v11)))))

(define (rzl-big [n : i64] [seed : i64])
  (:export-symbol "tl_rzl_big") : i64
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
    [v12 : i64 (+ seed 13)]
    [v13 : i64 (+ seed 14)]
    [v14 : i64 (+ seed 15)]
    [v15 : i64 (+ seed 16)]
    [v16 : i64 (+ seed 17)]
    [v17 : i64 (+ seed 18)]
    [v18 : i64 (+ seed 19)]
    [v19 : i64 (+ seed 20)]
    [v20 : i64 (+ seed 21)]
    [v21 : i64 (+ seed 22)]
    [v22 : i64 (+ seed 23)]
    [v23 : i64 (+ seed 24)]
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
          (set! acc (+ acc (* v12 i)))
          (set! acc (+ acc (* v13 i)))
          (set! acc (+ acc (* v14 i)))
          (set! acc (+ acc (* v15 i)))
          (set! acc (+ acc (* v16 i)))
          (set! acc (+ acc (* v17 i)))
          (set! acc (+ acc (* v18 i)))
          (set! acc (+ acc (* v19 i)))
          (set! acc (+ acc (* v20 i)))
          (set! acc (+ acc (* v21 i)))
          (set! acc (+ acc (* v22 i)))
          (set! acc (+ acc (* v23 i)))
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
          (set! v12 (+ v12 1))
          (set! v13 (+ v13 1))
          (set! v14 (+ v14 1))
          (set! v15 (+ v15 1))
          (set! v16 (+ v16 1))
          (set! v17 (+ v17 1))
          (set! v18 (+ v18 1))
          (set! v19 (+ v19 1))
          (set! v20 (+ v20 1))
          (set! v21 (+ v21 1))
          (set! v22 (+ v22 1))
          (set! v23 (+ v23 1))
          (set! i (+ i 1))))
      (+
        acc
        (+
          (+
            (+
              (+
                (+
                  (+
                    (+
                      (+
                        (+
                          (+
                            (+
                              (+
                                (+
                                  (+
                                    (+
                                      (+
                                        (+
                                          (+
                                            (+
                                              (+ (+ (+ (+ v0 v1) v2) v3) v4)
                                              v5)
                                            v6)
                                          v7)
                                        v8)
                                      v9)
                                    v10)
                                  v11)
                                v12)
                              v13)
                            v14)
                          v15)
                        v16)
                      v17)
                    v18)
                  v19)
                v20)
              v21)
            v22)
          v23)))))

(define (rzl-call [v : i64] [rounds : i64])
  (:export-symbol "tl_rzl_call") : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 4)
        (begin
          (set! acc (+ acc (rzl-probe i)))
          (set! acc (+ acc (* v i)))
          (set! acc (+ acc (* a i)))
          (set! acc (+ acc (* b i)))
          (set! a (+ a 1))
          (set! b (+ b 2))
          (set! i (+ i 1))))
      (if (> rounds 1)
        (+ acc (rzl-call v (- rounds 1)))
        (+ acc (+ a b))))))

(define (rzl-abort
  [xs : (__tl_dyn-array i64)]
  [n : i64]
  [seed : i64]
  [idx : i64])
  (:export-symbol "tl_rzl_abort") : i64
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
    ;; (io.arg-count) = 1 without args; it blocks constant folding.
    [v : i64 (io.arg-count)]
    [xs : (__tl_dyn-array i64) (array.make-array i64 4)]
    [_seed : unit (set! (array-ref xs 3) 11)]
    [s : i64 (rzl-slots (+ v 3) v)]
    [bg : i64 (rzl-big (+ v 3) v)]
    [c : i64 (rzl-call v 1)]
    [ab : i64 (rzl-abort xs (+ v 2) v (+ v 2))]
    (if (and (= s 3339) (= bg 5193) (= c 87) (= ab 2073))
      42
      1)))