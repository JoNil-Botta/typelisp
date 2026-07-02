(import stdlib.array)
(import "stdlib/io.tl")

;; FORCING TEST for GAP2b-v2: sound emergency-scavenge restore before a
;; switch-dispatch indirect jump.
;;
;; run-switch runs a mixing loop over 12 loop-carried accumulators (all
;; register-homed and live across the switch) and dispatches on a 6-variant
;; enum read from an array -- a jump-table switch (the vm_run shape). The 12
;; accumulators + i + the program handle saturate the 11-entry scavenger
;; candidate pool at the dispatch, so the jump-table-base scavenge goes
;; EMERGENCY and borrows a live occupant register. Under the OLD emitter that
;; register's restore landed AFTER the indirect jmp (unreachable): the
;; occupant arrived in the arms holding the jump-table address, corrupting
;; whichever accumulator/handle it homed. The fixed emitter stashes the
;; target and restores the occupant BEFORE a slot-indirect jump.
;;
;; run-ref runs the IDENTICAL mixing + per-op bump via branchless selection
;; (no switch -> never bug-prone). Clean codegen makes the two agree; any
;; dispatch clobber makes run-switch diverge. Returns 42 iff they agree.

(defenum Op (Op0) (Op1) (Op2) (Op3) (Op4) (Op5))

(define (run-switch [program : (Array Op)] [plen : i64] [n : i64] [seed : i64]) : i64
  (let [i : i64 0]
    [a0 : i64 (+ seed 111)]
    [a1 : i64 (+ seed 242)]
    [a2 : i64 (+ seed 373)]
    [a3 : i64 (+ seed 504)]
    [a4 : i64 (+ seed 635)]
    [a5 : i64 (+ seed 766)]
    [a6 : i64 (+ seed 897)]
    [a7 : i64 (+ seed 1028)]
    [a8 : i64 (+ seed 1159)]
    [a9 : i64 (+ seed 1290)]
    [a10 : i64 (+ seed 1421)]
    [a11 : i64 (+ seed 1552)]
    (begin
      (while (< i n)
        (begin
          (set! a0 (bit-and (+ (* a0 3) a1) 281474976710655))
          (set! a1 (bit-and (+ (* a1 3) a2) 281474976710655))
          (set! a2 (bit-and (+ (* a2 3) a3) 281474976710655))
          (set! a3 (bit-and (+ (* a3 3) a4) 281474976710655))
          (set! a4 (bit-and (+ (* a4 3) a5) 281474976710655))
          (set! a5 (bit-and (+ (* a5 3) a6) 281474976710655))
          (set! a6 (bit-and (+ (* a6 3) a7) 281474976710655))
          (set! a7 (bit-and (+ (* a7 3) a8) 281474976710655))
          (set! a8 (bit-and (+ (* a8 3) a9) 281474976710655))
          (set! a9 (bit-and (+ (* a9 3) a10) 281474976710655))
          (set! a10 (bit-and (+ (* a10 3) a11) 281474976710655))
          (set! a11 (bit-and (+ (* a11 3) a0) 281474976710655))
          (match (array.array-ref program (% i plen))
            [(Op0) (set! a0 (bit-and (+ a0 1000003) 281474976710655))]
            [(Op1) (set! a1 (bit-and (+ a1 1007922) 281474976710655))]
            [(Op2) (set! a2 (bit-and (+ a2 1015841) 281474976710655))]
            [(Op3) (set! a3 (bit-and (+ a3 1023760) 281474976710655))]
            [(Op4) (set! a4 (bit-and (+ a4 1031679) 281474976710655))]
            [(Op5) (set! a5 (bit-and (+ a5 1039598) 281474976710655))]
            )
          (set! i (+ i 1))))
      (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor a0 a1) a2) a3) a4) a5) a6) a7) a8) a9) a10) a11))))

(define (run-ref [n : i64] [seed : i64]) : i64
  (let [i : i64 0]
    [a0 : i64 (+ seed 111)]
    [a1 : i64 (+ seed 242)]
    [a2 : i64 (+ seed 373)]
    [a3 : i64 (+ seed 504)]
    [a4 : i64 (+ seed 635)]
    [a5 : i64 (+ seed 766)]
    [a6 : i64 (+ seed 897)]
    [a7 : i64 (+ seed 1028)]
    [a8 : i64 (+ seed 1159)]
    [a9 : i64 (+ seed 1290)]
    [a10 : i64 (+ seed 1421)]
    [a11 : i64 (+ seed 1552)]
    (begin
      (while (< i n)
        (let [op : i64 (% i 6)]
          (begin
            (set! a0 (bit-and (+ (* a0 3) a1) 281474976710655))
            (set! a1 (bit-and (+ (* a1 3) a2) 281474976710655))
            (set! a2 (bit-and (+ (* a2 3) a3) 281474976710655))
            (set! a3 (bit-and (+ (* a3 3) a4) 281474976710655))
            (set! a4 (bit-and (+ (* a4 3) a5) 281474976710655))
            (set! a5 (bit-and (+ (* a5 3) a6) 281474976710655))
            (set! a6 (bit-and (+ (* a6 3) a7) 281474976710655))
            (set! a7 (bit-and (+ (* a7 3) a8) 281474976710655))
            (set! a8 (bit-and (+ (* a8 3) a9) 281474976710655))
            (set! a9 (bit-and (+ (* a9 3) a10) 281474976710655))
            (set! a10 (bit-and (+ (* a10 3) a11) 281474976710655))
            (set! a11 (bit-and (+ (* a11 3) a0) 281474976710655))
            (set! a0 (bit-and (+ a0 (* 1000003 (if (= op 0) 1 0))) 281474976710655))
            (set! a1 (bit-and (+ a1 (* 1007922 (if (= op 1) 1 0))) 281474976710655))
            (set! a2 (bit-and (+ a2 (* 1015841 (if (= op 2) 1 0))) 281474976710655))
            (set! a3 (bit-and (+ a3 (* 1023760 (if (= op 3) 1 0))) 281474976710655))
            (set! a4 (bit-and (+ a4 (* 1031679 (if (= op 4) 1 0))) 281474976710655))
            (set! a5 (bit-and (+ a5 (* 1039598 (if (= op 5) 1 0))) 281474976710655))
            (set! i (+ i 1)))))
      (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor (bit-xor a0 a1) a2) a3) a4) a5) a6) a7) a8) a9) a10) a11))))

(define (main) : i64
  (let [p : (Array Op) (array.make-array Op 6)]
    (begin
      (array.array-set! p 0 (Op0))
      (array.array-set! p 1 (Op1))
      (array.array-set! p 2 (Op2))
      (array.array-set! p 3 (Op3))
      (array.array-set! p 4 (Op4))
      (array.array-set! p 5 (Op5))
      (let [n : i64 (+ (arg-count) 300)]
        [seed : i64 (+ (arg-count) 5)]
        [rs : i64 (run-switch p 6 n seed)]
        [rr : i64 (run-ref n seed)]
        (if (= rs rr) 42 1)))))
