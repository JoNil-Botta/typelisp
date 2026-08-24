;; FORCING TEST for copy_call's EIGHT-BYTE element tier (`tl_mem_copy8_fwd`).
;;
;; `(set! (array-ref dst i) (array-ref src i))` over `i64` elements is the shape
;; the optimizer's copy_call pass turns into ONE runtime call, replacing the
;; word-merge unroller's 11-instructions-per-four-elements body with a
;; `rep movsq` that the deterministic instruction-count gate charges one
;; instruction per element. scripts/verify-asm-shape-gates.sh asserts the shape;
;; this file's `main` is the correctness twin, and it is where the SEMANTICS the
;; helper exists for are pinned:
;;
;;   * `shift-up` is the propagating overlap. Its destination window sits ONE
;;     element above its source window inside the SAME array, so the loop
;;     re-reads elements it has just written and the whole tail ends up holding
;;     the FIRST element. A backward copy (memmove, which is what `tl_memcpy`
;;     is) or any chunk-at-a-time forward copy would leave the ORIGINAL elements
;;     shifted up by one instead, and `main` tells the two apart element by
;;     element. It is also what catches a byte count handed to a slot helper, or
;;     a slot count handed to the byte one: either copies the wrong number of
;;     bytes and the tail stops matching.
;;   * `shift-down` is the other overlap direction, where the destination is
;;     BELOW the source. Reading ahead of the write cannot matter there, so the
;;     helper takes its wide `rep movsq` arm, and the answer is the ordinary
;;     shifted sequence.
;;
;;   (What no run can distinguish is a helper that ran `rep movsq` on the
;;   propagating case too: the architecture describes REP MOVS as a sequence of
;;   individual element moves, so on a machine that honours that it produces the
;;   same answer. The scalar arm is there because fast-string operation is NOT
;;   promised to keep element granularity across overlapping regions; the shape
;;   gate is what pins its existence.)
;;
;; The refused neighbours are one-token edits that must NOT reach the word
;; helper: a `u32` element width, which has no total forward-copy helper at all,
;; and a THREE-element constant trip count, one below the pass's slot floor,
;; where the unrolled guard sends the loop straight to a five-instructions-per-
;; element body that is cheaper than the call. `copy-fixed4` is its neighbour on
;; the other side of that floor, one trip away. A missed rewrite is still
;; correct code, so only the shape gate can see those; `main` checks they all
;; still compute the right answers.
(define words : i64
  40)

;; --- admitted: the dynamic-length word copy ---------------------------------
(define (copy-words
  [dst : (__tl_dyn-array i64)]
  [src : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; --- admitted: the propagating overlap --------------------------------------
;; Destination one element ABOVE the source, same array: every write lands on an
;; element a later read consumes, so `a[1..n]` all end up holding `a[0]`.
(define (shift-up [a : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a (+ i 1)) (array-ref a i))
        (set! i (+ i 1))))))

;; --- admitted: the other overlap direction ----------------------------------
;; Destination BELOW the source: reads run ahead of the writes that could clobber
;; them, so this is the ordinary shift and the wide arm reproduces it.
(define (shift-down [a : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (array-ref a (+ i 1)))
        (set! i (+ i 1))))))

;; --- admitted: a fixed-size copy, and the slot floor's far side --------------
;; This is `pl-copy-line`'s shape -- two fixed-size array borrows and a
;; compile-time constant trip count -- which is the row the tier exists for.
(define (copy-fixed8
  [dst : (&mut dst (Array i64 9))]
  [src : (&mut src (Array i64 9))]) : unit
  (let
    [i : i64 0]
    (while (< i 8)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; FOUR elements: the floor itself. No unrolled group runs at four trips (the
;; version guard needs `i < bound - 4`), so the loop would be 21 instructions
;; against the call's 13 to 18, and the pass takes it.
(define (copy-fixed4
  [dst : (&mut dst (Array i64 9))]
  [src : (&mut src (Array i64 9))]) : unit
  (let
    [i : i64 0]
    (while (< i 4)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; --- refused: one trip below the slot floor ---------------------------------
;; THREE elements: 16 instructions against the call's 12 to 17. The pass
;; declines a bet it can lose.
(define (copy-fixed3
  [dst : (&mut dst (Array i64 9))]
  [src : (&mut src (Array i64 9))]) : unit
  (let
    [i : i64 0]
    (while (< i 3)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; --- refused: a width with no total forward-copy helper ----------------------
;; Neither `rep movsb` nor `rep movsq` moves `u32` elements atomically, so the
;; classifier answers "no width" and the loop keeps its unrolled body.
(define (copy-halfwords
  [dst : (__tl_dyn-array u32)]
  [src : (__tl_dyn-array u32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; --- the byte tier, which must keep naming the BYTE helper -------------------
(define (copy-bytes
  [dst : (__tl_dyn-array u8)]
  [src : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

;; --- correctness twin --------------------------------------------------------
(define (fill [xs : (&mut xs (__tl_dyn-array i64))] [seed : i64] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref xs i) (+ seed i))
        (set! i (+ i 1))))))

(define (all-equal?
  [xs : (& xs (__tl_dyn-array i64))]
  [from : i64]
  [to : i64]
  [want : i64]) : bool
  (let
    [i : i64 from]
    [ok : bool true]
    (begin
      (while (< i to)
        (begin
          (unless (= (array-ref xs i) want) (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (shifted-down?
  [xs : (& xs (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (unless (= (array-ref xs i) (+ seed (+ i 1))) (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [ha : (__tl_dyn-array u32) (__tl_make-array u32 (+ words 1))]
    [hb : (__tl_dyn-array u32) (__tl_make-array u32 (+ words 1))]
    [ba : (__tl_dyn-array u8) (__tl_make-array u8 (+ words 1))]
    [bb : (__tl_dyn-array u8) (__tl_make-array u8 (+ words 1))]
    [fa : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [fb : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [i : i64 0]
    (begin
      ;; Disjoint copy: the plain case, over an element count that is not a
      ;; multiple of four so an unrolled remainder would also have to run.
      (fill (&mut b) 500 words)
      (copy-words a b words)
      (unless (= (array-ref a 0) 500) (return 1))
      (unless (= (array-ref a 39) 539) (return 2))
      ;; PROPAGATION. `a[1..words]` must all hold the original `a[0]`; a
      ;; backward copy would leave them holding the original `a[k]`.
      (fill (&mut a) 900 (+ words 1))
      (shift-up a words)
      (unless (= (array-ref a 0) 900) (return 3))
      (unless (all-equal? (& a) 1 (+ words 1) 900) (return 4))
      ;; The other direction is the ordinary shift.
      (fill (&mut a) 300 (+ words 1))
      (shift-down a words)
      (unless (shifted-down? (& a) words 300) (return 5))
      (unless (= (array-ref a words) (+ 300 words)) (return 6))
      ;; One trip and zero trips, where the rotated body runs before any compare.
      (fill (&mut a) 700 (+ words 1))
      (shift-up a 1)
      (unless (= (array-ref a 1) 700) (return 7))
      (unless (= (array-ref a 2) 702) (return 8))
      (fill (&mut a) 700 (+ words 1))
      (shift-up a 0)
      (unless (= (array-ref a 1) 701) (return 9))
      (copy-words a b 0)
      (unless (= (array-ref a 0) 700) (return 10))
      ;; Fixed-size copies on both sides of the slot floor.
      (set! i 0)
      (while (< i 9)
        (begin
          (set! (array-ref fb i) (+ 40 i))
          (set! (array-ref fa i) 0)
          (set! i (+ i 1))))
      (copy-fixed8 (&mut fa) (&mut fb))
      (unless (= (array-ref fa 0) 40) (return 11))
      (unless (= (array-ref fa 7) 47) (return 12))
      (unless (= (array-ref fa 8) 0) (return 13))
      (set! i 0)
      (while (< i 9)
        (begin
          (set! (array-ref fa i) 0)
          (set! i (+ i 1))))
      (copy-fixed4 (&mut fa) (&mut fb))
      (unless (= (array-ref fa 0) 40) (return 14))
      (unless (= (array-ref fa 3) 43) (return 15))
      (unless (= (array-ref fa 4) 0) (return 16))
      (set! i 0)
      (while (< i 9)
        (begin
          (set! (array-ref fa i) 0)
          (set! i (+ i 1))))
      (copy-fixed3 (&mut fa) (&mut fb))
      (unless (= (array-ref fa 0) 40) (return 21))
      (unless (= (array-ref fa 2) 42) (return 22))
      (unless (= (array-ref fa 3) 0) (return 23))
      ;; Refused width, and the byte tier that must still fire.
      (set! i 0)
      (while (< i words)
        (begin
          (set! (array-ref hb i) (cast (+ 60 i) : u32))
          (set! (array-ref bb i) (cast (+ 3 i) : u8))
          (set! i (+ i 1))))
      (copy-halfwords ha hb words)
      (unless (= (cast (array-ref ha 0) : i64) 60) (return 17))
      (unless (= (cast (array-ref ha 39) : i64) 99) (return 18))
      (copy-bytes ba bb words)
      (unless (= (cast (array-ref ba 0) : i64) 3) (return 19))
      (unless (= (cast (array-ref ba 39) : i64) 42) (return 20))
      42)))