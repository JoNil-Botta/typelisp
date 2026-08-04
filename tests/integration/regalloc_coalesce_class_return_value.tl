(import stdlib.array)
(import stdlib.io)

;; Guards the VALUE of a spilled, repeatedly reassigned accumulator whose final
;; use is the function's return expression -- the one regalloc shape whose
;; miscompile is invisible to every checksum-style test in the tree.
;;
;; The shape, taken from the interner hash in src/compiler_intern.tl (and its
;; benchmark twin benchmarks/intern_table/bench.tl):
;;
;;   (set! h (* (bit-xor h tail) multiplier))          ; last write to h
;;   (bit-xor h (cast (shr (cast h : u64) 29) : i64))  ; return, reads h twice
;;
;; Two properties make this the hard case for the allocator. `h` is a mutable
;; multi-def value that survives two loops, so it spills; and the returned
;; value, the width-64 cast round trip, and the final `set!` are all move-related
;; to `h`, so the plan coalesces them into one class that inherits one spill
;; home. Later passes then REWRITE this IR -- loop-split region homing mints a
;; fresh register-resident var for the loop body and appends the write-back copy
;; to `h` at the region boundary -- which moves the last def of `h` AFTER the
;; def of the returned value. The stack colouring re-derives homes from that
;; final IR and keeps the two apart. Anything that instead trusts the pre-rewrite
;; class and hands both one home emits the write-back on top of the return value
;; and the function returns the pre-mix `h`.
;;
;; Why this needed its own test: a wrong hash is still a deterministic function,
;; so the interner still assigns identical ids, the benchmark still prints the
;; same checksum, and the register-allocator smoke -- which tests the allocator's
;; own predicates, not the code it emits -- still passes. Only a test that pins
;; the arithmetic RESULT of the emitted code fails. This one does.
;;
;; The input bytes come from (io.arg-count) so nothing folds at compile time and
;; the loops, the spill, and the region split all survive to codegen.
(define rccrv-multiplier : i64
  -7046029254386353131)

;; Eight bytes composed little-endian, so the value is host-endianness
;; independent, and the composition keeps a second multi-def accumulator (`word`)
;; alive across the loop.
(define (rccrv-load-word [src : (Array u8)] [at : i64]) : i64
  (let
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set!
            word
            (bit-or (shl word 8) (cast (array-ref src (+ at b)) : i64)))
          (set! b (- b 1))))
      word)))

(define (rccrv-mix [src : (Array u8)] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    [tail : i64 0]
    (begin
      (while (< i words)
        (begin
          (set!
            h
            (* (bit-xor h (rccrv-load-word src (+ start i))) rccrv-multiplier))
          (set! i (+ i 8))))
      (while (< i len)
        (begin
          (set! tail (+ (* tail 256) (cast (array-ref src (+ start i)) : i64)))
          (set! i (+ i 1))))
      (set! h (* (bit-xor h tail) rccrv-multiplier))
      (bit-xor h (cast (shr (cast h : u64) 29) : i64)))))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [src : (Array u8) (array.make-array u8 40)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i 40)
        (begin
          (array-set! src i (cast (+ (* i n) 65) : u8))
          (set! i (+ i 1))))
      ;; Every length from 1 to 29 covers the word loop alone, the tail loop
      ;; alone, and both together, so the final mix is reached from all three
      ;; predecessors of the return block.
      (set! i 1)
      (while (< i 30)
        (begin
          (set! acc (+ (* acc 31) (rccrv-mix src 0 i)))
          (set! i (+ i 1))))
      (if (= acc 4218076827798351321)
        42
        1))))