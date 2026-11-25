;; FORCING TEST for edge-precise scavenge occupancy. The inner `refine` loop is
;; rotated, and its counter's back-edge value is a phi input. Baseline liveness
;; counts that input as a use at the phi, so it looks live from function entry
;; through every block laid out ahead of the loop, and its register reads
;; occupied while the allocator has already given it to other values. The
;; variable shift that seeds `guess` then took its scratch with an emergency
;; save/restore around it. With the occupancy built on edge-precise liveness
;; (what the allocator assigns under) the scratch is simply free.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64 core) as i64vec)

(define (refine [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [bits : i64 0]
      [probe : i64 n]
      (while (> probe 0)
        (set! probe (shr probe 1))
        (set! bits (+ bits 1)))
      (let
        [guess : i64 (shl 1 (shr (+ bits 1) 1))]
        [iteration : i64 0]
        [settled : bool false]
        (while (and (< iteration 24) (not settled))
          (let
            [next : i64 (shr (+ guess (bit-xor n (shl guess 3))) 1)]
            (if (>= next guess)
              (set! settled true)
              (set! guess next))
            (set! iteration (+ iteration 1))))
        guess))))

(define (pairs
  [px : (&mut px (Slice i64))]
  [py : (&mut py (Slice i64))]
  [pm : (&mut pm (Slice i64))]
  [ox : (&mut ox (Slice i64))]
  [oy : (&mut oy (Slice i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (let
        [sx : i64 0]
        [sy : i64 0]
        [j : i64 0]
        (while (< j n)
          (when
            (!= j i)
            (let
              [dx : i64 (- (array-ref px j) (array-ref px i))]
              [dy : i64 (- (array-ref py j) (array-ref py i))]
              [d2 : i64 (+ (* dx dx) (* dy dy) 3)]
              [r : i64 (refine d2)]
              [ux : i64 (bit-xor (shl dx 5) r)]
              [uy : i64 (bit-xor (shl dy 5) r)]
              [w : i64 (bit-xor (* (array-ref pm j) 7) d2)]
              (set! sx (+ sx (bit-and (* w ux) 1048575)))
              (set! sy (+ sy (bit-and (* w uy) 1048575)))))
          (set! j (+ j 1)))
        (set! (array-ref ox i) sx)
        (set! (array-ref oy i) sy)
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [n : i64 24]
    [x : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [y : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [m : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [a : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [b : i64vec.Vec (i64vec.Vec (__tl_make-array i64 n) n)]
    [xv : (&mut x (Slice i64)) (i64vec.view-mut (&mut x))]
    [yv : (&mut y (Slice i64)) (i64vec.view-mut (&mut y))]
    [mv : (&mut m (Slice i64)) (i64vec.view-mut (&mut m))]
    [av : (&mut a (Slice i64)) (i64vec.view-mut (&mut a))]
    [bv : (&mut b (Slice i64)) (i64vec.view-mut (&mut b))]
    [k : i64 0]
    [acc : i64 0]
    (while (< k n)
      (set! (array-ref xv k) (* k 37))
      (set! (array-ref yv k) (bit-xor (* k 11) 5))
      (set! (array-ref mv k) (+ k 1))
      (set! k (+ k 1)))
    (pairs xv yv mv av bv n)
    (set! k 0)
    (while (< k n)
      (set!
        acc
        (bit-and (+ (* acc 31) (array-ref av k) (array-ref bv k)) 1048575))
      (set! k (+ k 1)))
    (io.println "{}" acc)
    42))