(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as vec)
(import compiler_owned_view as owned_view)

(define reads : vec.Vec
  (vec.Vec (__tl_make-array i64 1) 1))
(define writes : vec.Vec
  (vec.Vec (__tl_make-array i64 1) 1))

(define (read-at [index : i64]) : i64
  (array-ref (vec.slots (& reads)) index))

(define (write-at [index : i64] [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut writes)) index) value))

(define (work [count : i64] [index : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i count)
      (let
        [j : i64 0]
        (while (< j 2)
          (+= sum (read-at index))
          (+= j 1)))
      (write-at index (+ i 10))
      (+= i 1))
    sum))

(define (main) : i64
  (set! (array-ref (vec.slots-mut (&mut reads)) 0) 1)
  (let
    [alias? : bool (> (io.arg-count) 1)]
    ;; Deliberate unsafe representation alias: distinct global cells cannot
    ;; turn the shared backing buffer into two independent ownership roots.
    (when alias? (set! writes (owned_view.compiler-owned-shared-view reads)))
    (let
      [sum : i64 (work 4 0)]
      (io.println "sum={sum}")
      (if (=
        sum
        (if alias?
          68
          8))
        42
        1))))