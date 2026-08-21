;; FORCING TEST for GAP10 (memory-destination read-modify-write folding) and for
;; the word-merge unroll tier that sits on top of it.
;;
;; `(set! (array-ref a i) (bit-or (array-ref a i) (array-ref b i)))` is the
;; shape: the element is LOADED from an address, combined, and STORED BACK to
;; the same address. x86 does that in one instruction with a memory destination
;; (`orq %rSRC, (%rA,%rI,8)`), so the whole triple should cost two instructions
;; -- one to bring the other operand into a register, one to combine in place --
;; and only ONE when the other operand is already a register or an immediate.
;;
;; The refused neighbours below are the reason the fold needs an admission at
;; all. Each is a one-token edit of the admitted shape and each must keep the
;; three-instruction register round trip:
;;
;;   * `merge-shifted`   stores to a DIFFERENT element than it loaded;
;;   * `merge-reused`    reads the loaded element a second time, so the fold
;;                       cannot retire it;
;;   * `merge-interposed` stores to another array BETWEEN the load and the
;;                       store, so the window is not a read-modify-write;
;;   * `merge-bytes`     is byte-wide, where the load's extension and the
;;                       store's truncation stop agreeing with a `q` op.
;;
;; A missed fold is still CORRECT code, only slower, so the exit code cannot
;; catch it; scripts/verify-asm-shape-gates.sh asserts the shape. `main` is the
;; correctness twin: every kernel is checked against a hand-computed answer over
;; an ODD element count, so the unrolled fast body AND its remainder both run.
;; --- admitted: three ALU ops, each a pure word merge ------------------------
(define (merge-or
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-or (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (merge-and
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-and (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (merge-add
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

;; The one-instruction form: the other operand is a loop-invariant register, so
;; no staging load is needed at all.
(define (merge-reg [a : (&mut a (__tl_dyn-array i64))] [mask : i64] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-or (array-ref a i) mask))
        (set! i (+ i 1))))))

;; --- refused neighbours ------------------------------------------------------
;; The store address is `i + 1`, not `i`: the loaded word and the stored word
;; are different memory, so there is no read-modify-write to fold.
(define (merge-shifted
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a (+ i 1)) (bit-or (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

;; The loaded element is read TWICE -- once by the merge and once by the write
;; to `c` -- so the fold may not retire it and its home stays load-bearing.
(define (merge-reused
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [c : (&mut c (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (let
        [v : i64 (array-ref a i)]
        (begin
          (set! (array-ref a i) (bit-or v (array-ref b i)))
          (set! (array-ref c i) v)
          (set! i (+ i 1)))))))

;; Another store lands between the load and the store-back, so the window is no
;; longer a read-modify-write of one address and the fold must decline.
(define (merge-interposed
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [c : (&mut c (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (let
        [v : i64 (array-ref a i)]
        (begin
          (set! (array-ref c i) 7)
          (set! (array-ref a i) (bit-or v (array-ref b i)))
          (set! i (+ i 1)))))))

;; Byte-wide merge: the same source shape at a width the fold refuses.
(define (merge-bytes
  [a : (&mut a (__tl_dyn-array u8))]
  [b : (& b (__tl_dyn-array u8))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-or (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

;; The mixed-width container shape: a word payload updated alongside a NARROW
;; tag, which is what a slot table's state/key/value triple looks like once it
;; is scalarized. The word half still takes the memory-destination fold -- that
;; fold is per-instruction -- but the body as a whole is not a pure word merge,
;; so the unroll tier refuses it and the load-and-store class keeps it at K=2.
;; The two mechanisms are independent and this kernel is where that is pinned.
(define (merge-mixed
  [a : (&mut a (__tl_dyn-array i64))]
  [tags : (&mut tags (__tl_dyn-array u32))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-or (array-ref a i) 1))
        (set! (array-ref tags i) (bit-or (array-ref tags i) (cast 2 : u32)))
        (set! i (+ i 1))))))

;; --- correctness twin --------------------------------------------------------
(define words : i64
  9)

(define (fill [xs : (&mut xs (__tl_dyn-array i64))] [seed : i64]) : unit
  (let
    [i : i64 0]
    (while (< i words)
      (begin
        (set! (array-ref xs i) (+ seed i))
        (set! i (+ i 1))))))

(define (checksum [xs : (& xs (__tl_dyn-array i64))]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ (* acc 31) (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (expect-or) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ (* acc 31) (bit-or (+ 100 i) (+ 7 i))))
          (set! i (+ i 1))))
      acc)))

(define (expect-and) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ (* acc 31) (bit-and (+ 100 i) (+ 7 i))))
          (set! i (+ i 1))))
      acc)))

(define (expect-add) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ (* acc 31) (+ (+ 100 i) (+ 7 i))))
          (set! i (+ i 1))))
      acc)))

(define (expect-reg) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ (* acc 31) (bit-or (+ 100 i) 48)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [c : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [ba : (__tl_dyn-array u8) (__tl_make-array u8 (+ words 1))]
    [bb : (__tl_dyn-array u8) (__tl_make-array u8 (+ words 1))]
    [tags : (__tl_dyn-array u32) (__tl_make-array u32 (+ words 1))]
    [i : i64 0]
    (begin
      ;; Every kernel runs over an ODD word count, so an unrolled fast body and
      ;; its remainder iteration both execute on every call.
      (fill (&mut a) 100)
      (fill (&mut b) 7)
      (merge-or (&mut a) (& b) words)
      (unless (= (checksum (& a)) (expect-or)) (return 1))
      (fill (&mut a) 100)
      (merge-and (&mut a) (& b) words)
      (unless (= (checksum (& a)) (expect-and)) (return 2))
      (fill (&mut a) 100)
      (merge-add (&mut a) (& b) words)
      (unless (= (checksum (& a)) (expect-add)) (return 3))
      (fill (&mut a) 100)
      (merge-reg (&mut a) 48 words)
      (unless (= (checksum (& a)) (expect-reg)) (return 4))
      ;; Refused neighbours must still compute the same answers they always did.
      (fill (&mut a) 100)
      (merge-shifted (&mut a) (& b) words)
      (unless (= (array-ref a 1) (bit-or 100 7)) (return 5))
      (unless (= (array-ref a 0) 100) (return 6))
      (fill (&mut a) 100)
      (merge-reused (&mut a) (& b) (&mut c) words)
      (unless (= (checksum (& a)) (expect-or)) (return 7))
      (unless (= (array-ref c 3) 103) (return 8))
      (fill (&mut a) 100)
      (merge-interposed (&mut a) (& b) (&mut c) words)
      (unless (= (checksum (& a)) (expect-or)) (return 9))
      (unless (= (array-ref c 3) 7) (return 10))
      (set! i 0)
      (while (< i words)
        (begin
          (set! (array-ref ba i) (cast (+ 16 i) : u8))
          (set! (array-ref bb i) (cast (+ 3 i) : u8))
          (set! i (+ i 1))))
      (merge-bytes (&mut ba) (& bb) words)
      (unless (= (cast (array-ref ba 0) : i64) (bit-or 16 3)) (return 11))
      (unless (= (cast (array-ref ba 8) : i64) (bit-or 24 11)) (return 12))
      (fill (&mut a) 100)
      (set! i 0)
      (while (< i words)
        (begin
          (set! (array-ref tags i) (cast (* i 8) : u32))
          (set! i (+ i 1))))
      (merge-mixed (&mut a) (&mut tags) words)
      (unless (= (array-ref a 0) (bit-or 100 1)) (return 16))
      (unless (= (array-ref a 8) (bit-or 108 1)) (return 17))
      (unless (= (cast (array-ref tags 0) : i64) 2) (return 18))
      (unless (= (cast (array-ref tags 8) : i64) (bit-or 64 2)) (return 19))
      ;; Zero and one trip: the unrolled guard must send both straight to the
      ;; remainder loop.
      (fill (&mut a) 100)
      (merge-or (&mut a) (& b) 0)
      (unless (= (array-ref a 0) 100) (return 13))
      (merge-or (&mut a) (& b) 1)
      (unless (= (array-ref a 0) (bit-or 100 7)) (return 14))
      (unless (= (array-ref a 1) 101) (return 15))
      42)))