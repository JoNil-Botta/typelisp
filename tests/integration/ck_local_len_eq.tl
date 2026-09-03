;; CK-1: twin arrays allocated in ONE function with GVN-equal lengths.
;;
;; Three shapes in one body, all indexed with the SAME cursor:
;;   `xs`/`ys`  a single-return allocating helper called twice with one length
;;   `ps`/`qs`  two `__tl_make-array`s with one length var
;;   `zs`       a longer array, which belongs to neither family
;; The second check of each twin pair is the one CK-1 retires; the first stays
;; and is the site any out-of-range cursor aborts at (ck_local_len_eq_abort).
;; The exit code carries the accumulated value, so a wrong retirement shows up
;; as a wrong number rather than as a silent pass.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (ck-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (ck-run [n : i64] [bump : i64]) : i64
  (let
    [xs : i64vec.Vec (ck-zero-vec n)]
    [ys : i64vec.Vec (ck-zero-vec n)]
    [zs : i64vec.Vec (ck-zero-vec (+ n 4))]
    [ps (__tl_make-array i64 n)]
    [qs (__tl_make-array i64 n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut xs)) i) (* i 3))
          (set! (array-ref (i64vec.slots-mut (&mut ys)) i) (+ i 1))
          (set! (array-ref ps i) (* i 2))
          (set! (array-ref qs i) (+ i 5))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i (+ n 4))
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut zs)) i) i)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i n)
        (let
          [cursor : i64 (+ i bump)]
          (begin
            (set! acc (+ acc (array-ref (i64vec.slots (& xs)) cursor)))
            (set! acc (+ acc (array-ref (i64vec.slots (& ys)) cursor)))
            (set! acc (+ acc (array-ref ps cursor)))
            (set! acc (+ acc (array-ref qs cursor)))
            (set! acc (+ acc (array-ref (i64vec.slots (& zs)) cursor)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (io.print-format "{}\n" (ck-run n bump))
      42)))