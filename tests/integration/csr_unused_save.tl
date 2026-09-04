(import stdlib.io)

;; FORCING TEST for RG-1 fix B: a callee-saved register the BODY never names.
;;
;; `probe` is the open-addressing probe of benchmarks/callgraph_scc's map, cut
;; down to the shape that produces the defect: a while loop over a global
;; three-word slot array whose arms each recompute the cursor, driven from a
;; caller that runs it often enough for the prologue to matter. The allocator
;; homes one of the loop's values in a callee-saved register and emission then
;; leaves that register unnamed -- the mentions it was priced on are a
;; coalesce-class copy the peephole elides and a compare whose operand folds --
;; so before the fix the prologue pushes a register the body never reads and
;; the epilogue pops it back, on every one of the calls.
;;
;; target/asm-shape check-csr-unused-save asserts every pushed callee-saved
;; register is named by the body (FAILS before the fix, where %r13 is pushed
;; and popped and appears nowhere else: proven forcing), and the manifest rows
;; pin the result the loop computes on both native targets.
(define csr-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 192))

(define (probe [base : i64] [cap : i64] [key : i64]) : i64
  (let
    [mask : i64 (- cap 1)]
    [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
    [walked : i64 0]
    [first : i64 -1]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (and (< walked cap) (not done))
        (let
          [state : i64 (array-ref csr-slots (+ base (* cursor 3)))]
          (cond
            [(= state 2)
              (if (= (array-ref csr-slots (+ base (+ (* cursor 3) 1))) key)
                (begin
                  (set! found cursor)
                  (set! done true))
                (begin
                  (set! cursor (bit-and (+ cursor 1) mask))
                  (set! walked (+ walked 1))))]
            [(= state 0)
              (begin
                (set!
                  found
                  (-
                    0
                    (+
                      2
                      (if (>= first 0)
                        first
                        cursor))))
                (set! done true))]
            [else
              (begin
                (when (< first 0) (set! first cursor))
                (set! cursor (bit-and (+ cursor 1) mask))
                (set! walked (+ walked 1)))])))
      (if done
        found
        (if (>= first 0)
          (- 0 (+ 2 first))
          -1)))))

(define (insert! [base : i64] [cap : i64] [key : i64] [value : i64]) : unit
  (let
    [slot : i64 (probe base cap key)]
    (if (>= slot 0)
      (set! (array-ref csr-slots (+ base (+ (* slot 3) 2))) value)
      (let
        [index : i64 (- (- 0 slot) 2)]
        (begin
          (set! (array-ref csr-slots (+ base (* index 3))) 2)
          (set! (array-ref csr-slots (+ base (+ (* index 3) 1))) key)
          (set! (array-ref csr-slots (+ base (+ (* index 3) 2))) value))))))

(define (lookup [base : i64] [cap : i64] [key : i64] [fallback : i64]) : i64
  (let
    [slot : i64 (probe base cap key)]
    (if (>= slot 0)
      (array-ref csr-slots (+ base (+ (* slot 3) 2)))
      fallback)))

(define (fill! [rounds : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (insert! 0 64 (+ (* i 7) 1) (+ i 3))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i rounds)
        (begin
          (set! total (+ total (lookup 0 64 (+ (* i 7) 1) 0)))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [total : i64 (fill! 40)]
    (begin
      (io.print-format "{}\n" total)
      (if (= total 900)
        42
        1))))