;; ALIAS-2. A module-global descriptor chain reloaded across a store-free leaf
;; call, in a program whose globals OVERFLOW both packed per-global rows -- the
;; exact shape benchmarks/ssa_construct's `ssa-dominance-frontier` runs, and the
;; one the packet's rule is about.
;;
;; `aro-scan`'s loop indexes two global vectors and calls `aro-marked?`, a leaf
;; that reads a third and writes nothing, on every trip. The cell word, the
;; descriptor handle behind it and that descriptor's length and data words are
;; loop-invariant in fact: the callee writes no memory at all, so nothing in
;; the body can change any of them.
;;
;; The rows that say so are packed into one i64 each -- IAG-2's storage row over
;; the non-scalar globals, P18's cell row over the ones some `set!` names -- and
;; this program declares 63 of each, one past their 62-bit capacity. Before the
;; rule the builders DECLINED both tables for the whole program on those counts
;; alone: every loop was seeded "may write any cell / any storage", the head of
;; every descriptor chain was refused, and the length and data words behind it
;; stayed in with it. With the rule the globals past the capacity share the last
;; bit, both tables survive, and the two chains leave this loop.
;;
;; `aro-alloc!` is the only writer of any cell here and it never READS one, so
;; IAG-1's classification keeps the cells inline and the chains have the
;; `gep @g, 0` head this packet is about.
;;
;; `bump` shifts the read one past the end. At 0 every read is in range and the
;; printed fold pins the result; at 1 the last read is exactly at `length`, so
;; the run must still abort at that load with the same located message the base
;; compiler produced.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (aro-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (aro-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (aro-set! [items : (&mut items i64vec.Vec)] [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

;; The two the hot loop walks.
(define aro-edge : i64vec.Vec
  (aro-zero-vec 1))
(define aro-mark : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-00 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-01 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-02 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-03 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-04 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-05 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-06 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-07 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-08 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-09 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-10 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-11 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-12 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-13 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-14 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-15 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-16 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-17 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-18 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-19 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-20 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-21 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-22 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-23 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-24 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-25 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-26 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-27 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-28 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-29 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-30 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-31 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-32 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-33 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-34 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-35 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-36 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-37 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-38 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-39 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-40 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-41 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-42 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-43 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-44 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-45 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-46 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-47 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-48 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-49 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-50 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-51 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-52 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-53 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-54 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-55 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-56 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-57 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-58 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-59 : i64vec.Vec
  (aro-zero-vec 1))
(define aro-pad-60 : i64vec.Vec
  (aro-zero-vec 1))

;; A store-free leaf that READS a global vector -- opt-dom-info-dominates-id?'s
;; shape. Its call-memory summary is 0, so it carries bit 0 ("writes no memory
;; at all") and cannot change a descriptor word the caller already loaded.
(define (aro-marked? [a : i64] [b : i64]) : bool
  (let
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index 2)
        (begin
          (unless
            (=
              (aro-ref
                (& aro-mark)
                (if (= index 0)
                  a
                  b))
              1)
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

;; The hot loop: two global descriptor chains, one call to the leaf per trip.
(define (aro-scan [n : i64] [bump : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index n)
        (let
          [edge : i64 (aro-ref (& aro-edge) (+ index bump))]
          (begin
            (when
              (and (= (aro-ref (& aro-mark) index) 1) (aro-marked? edge index))
              (set! acc (+ (* acc 31) edge)))
            (set! index (+ index 1)))))
      acc)))

;; The only cell writer in the program. It fills LOCAL vectors and stores them,
;; so it never READS a cell -- which is what keeps IAG-1's classification from
;; excluding these globals for "a function that reads it also rebinds it".
(define (aro-alloc! [n : i64]) : unit
  (let
    [edge : i64vec.Vec (aro-zero-vec n)]
    [mark : i64vec.Vec (aro-zero-vec n)]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (aro-set! (&mut edge) index (% (* index 7) n))
          (aro-set! (&mut mark) index (% index 2))
          (set! index (+ index 1))))
      (set! aro-edge edge)
      (set! aro-mark mark)
      (set! aro-pad-00 (aro-zero-vec 1))
      (set! aro-pad-01 (aro-zero-vec 1))
      (set! aro-pad-02 (aro-zero-vec 1))
      (set! aro-pad-03 (aro-zero-vec 1))
      (set! aro-pad-04 (aro-zero-vec 1))
      (set! aro-pad-05 (aro-zero-vec 1))
      (set! aro-pad-06 (aro-zero-vec 1))
      (set! aro-pad-07 (aro-zero-vec 1))
      (set! aro-pad-08 (aro-zero-vec 1))
      (set! aro-pad-09 (aro-zero-vec 1))
      (set! aro-pad-10 (aro-zero-vec 1))
      (set! aro-pad-11 (aro-zero-vec 1))
      (set! aro-pad-12 (aro-zero-vec 1))
      (set! aro-pad-13 (aro-zero-vec 1))
      (set! aro-pad-14 (aro-zero-vec 1))
      (set! aro-pad-15 (aro-zero-vec 1))
      (set! aro-pad-16 (aro-zero-vec 1))
      (set! aro-pad-17 (aro-zero-vec 1))
      (set! aro-pad-18 (aro-zero-vec 1))
      (set! aro-pad-19 (aro-zero-vec 1))
      (set! aro-pad-20 (aro-zero-vec 1))
      (set! aro-pad-21 (aro-zero-vec 1))
      (set! aro-pad-22 (aro-zero-vec 1))
      (set! aro-pad-23 (aro-zero-vec 1))
      (set! aro-pad-24 (aro-zero-vec 1))
      (set! aro-pad-25 (aro-zero-vec 1))
      (set! aro-pad-26 (aro-zero-vec 1))
      (set! aro-pad-27 (aro-zero-vec 1))
      (set! aro-pad-28 (aro-zero-vec 1))
      (set! aro-pad-29 (aro-zero-vec 1))
      (set! aro-pad-30 (aro-zero-vec 1))
      (set! aro-pad-31 (aro-zero-vec 1))
      (set! aro-pad-32 (aro-zero-vec 1))
      (set! aro-pad-33 (aro-zero-vec 1))
      (set! aro-pad-34 (aro-zero-vec 1))
      (set! aro-pad-35 (aro-zero-vec 1))
      (set! aro-pad-36 (aro-zero-vec 1))
      (set! aro-pad-37 (aro-zero-vec 1))
      (set! aro-pad-38 (aro-zero-vec 1))
      (set! aro-pad-39 (aro-zero-vec 1))
      (set! aro-pad-40 (aro-zero-vec 1))
      (set! aro-pad-41 (aro-zero-vec 1))
      (set! aro-pad-42 (aro-zero-vec 1))
      (set! aro-pad-43 (aro-zero-vec 1))
      (set! aro-pad-44 (aro-zero-vec 1))
      (set! aro-pad-45 (aro-zero-vec 1))
      (set! aro-pad-46 (aro-zero-vec 1))
      (set! aro-pad-47 (aro-zero-vec 1))
      (set! aro-pad-48 (aro-zero-vec 1))
      (set! aro-pad-49 (aro-zero-vec 1))
      (set! aro-pad-50 (aro-zero-vec 1))
      (set! aro-pad-51 (aro-zero-vec 1))
      (set! aro-pad-52 (aro-zero-vec 1))
      (set! aro-pad-53 (aro-zero-vec 1))
      (set! aro-pad-54 (aro-zero-vec 1))
      (set! aro-pad-55 (aro-zero-vec 1))
      (set! aro-pad-56 (aro-zero-vec 1))
      (set! aro-pad-57 (aro-zero-vec 1))
      (set! aro-pad-58 (aro-zero-vec 1))
      (set! aro-pad-59 (aro-zero-vec 1))
      (set! aro-pad-60 (aro-zero-vec 1)))))

;; Touch every padding vector so it survives into the emitted program.
(define (aro-pad-fold) : i64
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
                                                                                                                    (+
                                                                                                                      (+
                                                                                                                        (+
                                                                                                                          (+
                                                                                                                            0
                                                                                                                            (aro-ref
                                                                                                                              (&
                                                                                                                                aro-pad-00)
                                                                                                                              0))
                                                                                                                          (aro-ref
                                                                                                                            (&
                                                                                                                              aro-pad-01)
                                                                                                                            0))
                                                                                                                        (aro-ref
                                                                                                                          (&
                                                                                                                            aro-pad-02)
                                                                                                                          0))
                                                                                                                      (aro-ref
                                                                                                                        (&
                                                                                                                          aro-pad-03)
                                                                                                                        0))
                                                                                                                    (aro-ref
                                                                                                                      (&
                                                                                                                        aro-pad-04)
                                                                                                                      0))
                                                                                                                  (aro-ref
                                                                                                                    (&
                                                                                                                      aro-pad-05)
                                                                                                                    0))
                                                                                                                (aro-ref
                                                                                                                  (&
                                                                                                                    aro-pad-06)
                                                                                                                  0))
                                                                                                              (aro-ref
                                                                                                                (&
                                                                                                                  aro-pad-07)
                                                                                                                0))
                                                                                                            (aro-ref
                                                                                                              (&
                                                                                                                aro-pad-08)
                                                                                                              0))
                                                                                                          (aro-ref
                                                                                                            (&
                                                                                                              aro-pad-09)
                                                                                                            0))
                                                                                                        (aro-ref
                                                                                                          (&
                                                                                                            aro-pad-10)
                                                                                                          0))
                                                                                                      (aro-ref
                                                                                                        (&
                                                                                                          aro-pad-11)
                                                                                                        0))
                                                                                                    (aro-ref
                                                                                                      (&
                                                                                                        aro-pad-12)
                                                                                                      0))
                                                                                                  (aro-ref
                                                                                                    (&
                                                                                                      aro-pad-13)
                                                                                                    0))
                                                                                                (aro-ref
                                                                                                  (&
                                                                                                    aro-pad-14)
                                                                                                  0))
                                                                                              (aro-ref
                                                                                                (&
                                                                                                  aro-pad-15)
                                                                                                0))
                                                                                            (aro-ref
                                                                                              (&
                                                                                                aro-pad-16)
                                                                                              0))
                                                                                          (aro-ref
                                                                                            (&
                                                                                              aro-pad-17)
                                                                                            0))
                                                                                        (aro-ref
                                                                                          (&
                                                                                            aro-pad-18)
                                                                                          0))
                                                                                      (aro-ref
                                                                                        (&
                                                                                          aro-pad-19)
                                                                                        0))
                                                                                    (aro-ref
                                                                                      (&
                                                                                        aro-pad-20)
                                                                                      0))
                                                                                  (aro-ref
                                                                                    (&
                                                                                      aro-pad-21)
                                                                                    0))
                                                                                (aro-ref
                                                                                  (&
                                                                                    aro-pad-22)
                                                                                  0))
                                                                              (aro-ref
                                                                                (&
                                                                                  aro-pad-23)
                                                                                0))
                                                                            (aro-ref
                                                                              (&
                                                                                aro-pad-24)
                                                                              0))
                                                                          (aro-ref
                                                                            (&
                                                                              aro-pad-25)
                                                                            0))
                                                                        (aro-ref
                                                                          (&
                                                                            aro-pad-26)
                                                                          0))
                                                                      (aro-ref
                                                                        (&
                                                                          aro-pad-27)
                                                                        0))
                                                                    (aro-ref
                                                                      (&
                                                                        aro-pad-28)
                                                                      0))
                                                                  (aro-ref
                                                                    (&
                                                                      aro-pad-29)
                                                                    0))
                                                                (aro-ref
                                                                  (& aro-pad-30)
                                                                  0))
                                                              (aro-ref
                                                                (& aro-pad-31)
                                                                0))
                                                            (aro-ref
                                                              (& aro-pad-32)
                                                              0))
                                                          (aro-ref
                                                            (& aro-pad-33)
                                                            0))
                                                        (aro-ref
                                                          (& aro-pad-34)
                                                          0))
                                                      (aro-ref (& aro-pad-35) 0))
                                                    (aro-ref (& aro-pad-36) 0))
                                                  (aro-ref (& aro-pad-37) 0))
                                                (aro-ref (& aro-pad-38) 0))
                                              (aro-ref (& aro-pad-39) 0))
                                            (aro-ref (& aro-pad-40) 0))
                                          (aro-ref (& aro-pad-41) 0))
                                        (aro-ref (& aro-pad-42) 0))
                                      (aro-ref (& aro-pad-43) 0))
                                    (aro-ref (& aro-pad-44) 0))
                                  (aro-ref (& aro-pad-45) 0))
                                (aro-ref (& aro-pad-46) 0))
                              (aro-ref (& aro-pad-47) 0))
                            (aro-ref (& aro-pad-48) 0))
                          (aro-ref (& aro-pad-49) 0))
                        (aro-ref (& aro-pad-50) 0))
                      (aro-ref (& aro-pad-51) 0))
                    (aro-ref (& aro-pad-52) 0))
                  (aro-ref (& aro-pad-53) 0))
                (aro-ref (& aro-pad-54) 0))
              (aro-ref (& aro-pad-55) 0))
            (aro-ref (& aro-pad-56) 0))
          (aro-ref (& aro-pad-57) 0))
        (aro-ref (& aro-pad-58) 0))
      (aro-ref (& aro-pad-59) 0))
    (aro-ref (& aro-pad-60) 0)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (aro-alloc! count)
      (io.print-format "{}\n" (+ (aro-scan count bump) (aro-pad-fold)))
      42)))