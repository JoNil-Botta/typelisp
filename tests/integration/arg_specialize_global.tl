;; LGA-1 runtime coverage: three module-global Vecs and three helpers that take
;; them as reference parameters. `spec-sum` and `spec-push!` are handed the SAME
;; global at every direct call site, so the specialization substitutes the
;; global for the parameter and drops the argument at both sites -- including
;; the `(&mut ...)` one, whose `push-ref!` grows the global's own storage
;; through the former parameter. `spec-scale` is handed a global at one site and
;; a local at the other, so it keeps its parameter and both calls keep their
;; argument. Every printed value pins a result the rewrite must not change.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define spec-data : i64vec.Vec
  (zero-vec 1))
(define spec-log : i64vec.Vec
  (zero-vec 1))

(define (spec-sum [v : (& v i64vec.Vec)] [count : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! acc (+ acc (array-ref (i64vec.slots v) i)))
          (set! i (+ i 1))))
      acc)))

(define (spec-push! [v : (&mut v i64vec.Vec)] [value : i64]) : unit
  (i64vec.push-ref! v value))

(define (spec-scale [v : (& v i64vec.Vec)] [count : i64] [factor : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! acc (+ acc (* factor (array-ref (i64vec.slots v) i))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [i : i64 0]
    [local : i64vec.Vec (zero-vec n)]
    [first : i64 0]
    [second : i64 0]
    (begin
      (set! spec-data (zero-vec n))
      (set! spec-log (i64vec.Vec (__tl_make-array i64 0) 0))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut spec-data)) i) (+ i 1))
          (set! (array-ref (i64vec.slots-mut (&mut local)) i) 2)
          (set! i (+ i 1))))
      (set! first (spec-sum (& spec-data) n))
      (set! second (spec-sum (& spec-data) (- n 1)))
      (spec-push! (&mut spec-log) first)
      (spec-push! (&mut spec-log) second)
      (io.print-format "{}\n" first)
      (io.print-format "{}\n" (i64vec.len (& spec-log)))
      (io.print-format
        "{}\n"
        (+
          (array-ref (i64vec.slots (& spec-log)) 0)
          (array-ref (i64vec.slots (& spec-log)) 1)))
      (io.print-format "{}\n" (spec-scale (& spec-data) n 3))
      (io.print-format "{}\n" (spec-scale (& local) n 5))
      42)))