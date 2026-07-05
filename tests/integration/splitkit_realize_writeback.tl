(import stdlib.io)

;; SplitKit M3 FORCING TEST -- realized register-piece split WITH write-back.
;;
;; A loop-carried value `w` is used BEFORE a real call each iteration and
;; REDEFINED AFTER it, inside a call-free (clobber-free) post-call sub-range.
;; Under `--cfg splitkit-stress` the greedy spills `w` (register pressure across
;; the call) and splits it; the M3 realization homes `w`'s post-call sub-range in
;; a register and -- because `w` is redefined there -- inserts a WRITE-BACK copy
;; `Mov w-slot <- reg` before the sub-range exit so `w`'s canonical slot (read on
;; the next iteration and after the loop) holds the updated value.
;;
;; SOUNDNESS GUARD: if the write-back is dropped (or emitted after the exit, or
;; targets the wrong slot), the next iteration / the final read sees a stale slot
;; and the sum is wrong -> exit 1. This is the redefined-value OUT-copy the design
;; guards with `copies-bidirectional?`; the test fails loudly if it is missing.
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (wb_hot [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    [d : i64 (+ n 4)]
    [e : i64 (+ n 5)]
    [f : i64 (+ n 6)]
    [g : i64 (+ n 7)]
    [h : i64 (+ n 8)]
    [w : i64 (+ n 100)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 4)
        (begin
          ;; use a..h AND w BEFORE the call (pressure + keep w live across it)
          (set!
            acc
            (+
              acc
              (+
                w
                (+
                  (* a 3)
                  (+
                    (* b 3)
                    (+
                      (* c 3)
                      (+ (* d 3) (+ (* e 3) (+ (* f 3) (+ (* g 3) (* h 3)))))))))))
          (set! acc (+ acc (clobber i)))
          ;; post-call clobber-free sub-range: REDEFINE w (write-back piece)
          (set!
            w
            (+
              w
              (+
                (* a 5)
                (+
                  (* b 5)
                  (+
                    (* c 5)
                    (+ (* d 5) (+ (* e 5) (+ (* f 5) (+ (* g 5) (* h 5))))))))))
          (set! acc (+ acc w))
          (set! i (+ i 1))))
      (+ acc w))))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r : i64 (wb_hot n)]
    ;; n=1: a..h = 2..9, sum44 = 44. w starts at 101.
    ;; Each iteration (i=0..3):
    ;;   acc += w + 3*44 = w + 132   (w is the value BEFORE this iter's redef)
    ;;   acc += clobber(i) = i+1
    ;;   w   += 5*44 = w + 220
    ;;   acc += w    (the new w)
    ;; Track w and acc:
    ;;   i=0: acc+= 101+132=233; acc+=1; w=101+220=321; acc+=321  -> acc=233+1+321=555
    ;;   i=1: acc+=321+132=453; acc+=2; w=321+220=541; acc+=541  -> acc=555+453+2+541=1551
    ;;   i=2: acc+=541+132=673; acc+=3; w=541+220=761; acc+=761  -> acc=1551+673+3+761=2988
    ;;   i=3: acc+=761+132=893; acc+=4; w=761+220=981; acc+=981  -> acc=2988+893+4+981=4866
    ;;   return acc + w = 4866 + 981 = 5847
    (if (= r 5847)
      42
      1)))
