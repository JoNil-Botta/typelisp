;# benchmarks/graph_dijkstra/bench.tl - binary-heap Dijkstra on a CSR graph.
;#
;# Equivalent to benchmarks/graph_dijkstra/baseline.c. A deterministic LCG
;# builds one directed graph of `vertices` vertices in compressed sparse row
;# form: an offset array of length `vertices + 1` plus target and weight arrays.
;# Each vertex gets two to six out-edges (four on average), every target is a
;# uniform vertex id, and every weight lies in `[1, 2^20)`.
;#
;# Each round runs Dijkstra from a round-dependent source and folds the sum of
;# the reached distances, taken modulo a prime, into a rolling accumulator. The
;# priority queue is a hand-rolled array-based binary min-heap: 0-based, parent
;# `(i - 1) / 2`, children `2i + 1` and `2i + 2`, sift-up after a push and
;# sift-down after moving the last element to the root. There is no decrease-key
;# operation; a relaxation that improves `dist` pushes a second entry for the
;# same vertex, and a `settled` flag makes the pop discard stale entries. The
;# heap therefore holds at most `edges + 1` entries. Both implementations run
;# exactly this variant, so the two sides agree entry for entry.
;#
;# The vertex count and round count are runtime arguments, so nothing can be
;# constant folded, and the accumulator stays in `[0, prime)` so the printed
;# decimal matches the C baseline's `%lld`.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define gd-modulus : i64
  1000000007)

;; Larger than any reachable distance in this graph family.
(define gd-infinity : i64
  4611686018427387904)
(define gd-weight-limit : i64
  1048576)
(define gd-max-degree : i64
  6)

;; 64-bit LCG. The state advances over the full word and every drawn value comes
;; from the high bits, whose period is much longer than the low bits'.
(define (gd-next-state [state : i64]) : i64
  (+ (* state 6364136223846793005) 1442695040888963407))

(define (gd-draw [state : i64]) : i64
  (bit-and (shr state 33) 2147483647))

(define (gd-build
  [offsets : (Array i64)]
  [targets : (Array i64)]
  [weights : (Array i64)]
  [vertices : i64]
  [seed : i64]) : i64
  (let
    [state : i64 seed]
    [cursor : i64 0]
    [v : i64 0]
    [e : i64 0]
    (begin
      (while (< v vertices)
        (begin
          (array-set! offsets v cursor)
          (set! state (gd-next-state state))
          (set! cursor (+ cursor (+ 2 (% (gd-draw state) 5))))
          (set! v (+ v 1))))
      (array-set! offsets vertices cursor)
      (while (< e cursor)
        (begin
          (set! state (gd-next-state state))
          (array-set! targets e (% (gd-draw state) vertices))
          (set! state (gd-next-state state))
          (array-set! weights e (+ 1 (% (gd-draw state) (- gd-weight-limit 1))))
          (set! e (+ e 1))))
      cursor)))

(define (gd-swap [xs : (Array i64)] [i : i64] [j : i64]) : unit
  (let
    [tmp : i64 (array-ref xs i)]
    (begin
      (array-set! xs i (array-ref xs j))
      (array-set! xs j tmp))))

(define (gd-dijkstra
  [offsets : (Array i64)]
  [targets : (Array i64)]
  [weights : (Array i64)]
  [dist : (Array i64)]
  [settled : (Array i64)]
  [heap-key : (Array i64)]
  [heap-node : (Array i64)]
  [vertices : i64]
  [source : i64]) : i64
  (let
    [i : i64 0]
    [heap-size : i64 0]
    [total : i64 0]
    (begin
      (while (< i vertices)
        (begin
          (array-set! dist i gd-infinity)
          (array-set! settled i 0)
          (set! i (+ i 1))))
      (array-set! dist source 0)
      (array-set! heap-key 0 0)
      (array-set! heap-node 0 source)
      (set! heap-size 1)
      (while (> heap-size 0)
        (let
          [top-key : i64 (array-ref heap-key 0)]
          [top-node : i64 (array-ref heap-node 0)]
          [slot : i64 0]
          [sifting : bool true]
          (begin
            (set! heap-size (- heap-size 1))
            (array-set! heap-key 0 (array-ref heap-key heap-size))
            (array-set! heap-node 0 (array-ref heap-node heap-size))
            (while sifting
              (let
                [left : i64 (+ (* slot 2) 1)]
                [right : i64 (+ (* slot 2) 2)]
                [best : i64 slot]
                (begin
                  (when
                    (and
                      (< left heap-size)
                      (< (array-ref heap-key left) (array-ref heap-key best)))
                    (set! best left))
                  (when
                    (and
                      (< right heap-size)
                      (< (array-ref heap-key right) (array-ref heap-key best)))
                    (set! best right))
                  (if (= best slot)
                    (set! sifting false)
                    (begin
                      (gd-swap heap-key slot best)
                      (gd-swap heap-node slot best)
                      (set! slot best))))))
            (when
              (= (array-ref settled top-node) 0)
              (let
                [e : i64 (array-ref offsets top-node)]
                [stop : i64 (array-ref offsets (+ top-node 1))]
                (begin
                  (array-set! settled top-node 1)
                  (while (< e stop)
                    (let
                      [next : i64 (array-ref targets e)]
                      [relaxed : i64 (+ top-key (array-ref weights e))]
                      (begin
                        (when
                          (< relaxed (array-ref dist next))
                          (let
                            [child : i64 heap-size]
                            (begin
                              (array-set! dist next relaxed)
                              (array-set! heap-key heap-size relaxed)
                              (array-set! heap-node heap-size next)
                              (set! heap-size (+ heap-size 1))
                              (while (and
                                (> child 0)
                                (>
                                  (array-ref heap-key (/ (- child 1) 2))
                                  (array-ref heap-key child)))
                                (begin
                                  (gd-swap heap-key child (/ (- child 1) 2))
                                  (gd-swap heap-node child (/ (- child 1) 2))
                                  (set! child (/ (- child 1) 2)))))))
                        (set! e (+ e 1)))))))))))
      (set! i 0)
      (while (< i vertices)
        (begin
          (when
            (< (array-ref dist i) gd-infinity)
            (set! total (% (+ total (array-ref dist i)) gd-modulus)))
          (set! i (+ i 1))))
      total)))

(define (gd-bench [vertices : i64] [rounds : i64]) : i64
  (let
    [offsets : (Array i64) (array.make-array i64 (+ vertices 1))]
    [targets : (Array i64) (array.make-array i64 (* vertices gd-max-degree))]
    [weights : (Array i64) (array.make-array i64 (* vertices gd-max-degree))]
    [dist : (Array i64) (array.make-array i64 vertices)]
    [settled : (Array i64) (array.make-array i64 vertices)]
    [heap-key : (Array i64)
      (array.make-array i64 (+ (* vertices gd-max-degree) 2))]
    [heap-node : (Array i64)
      (array.make-array i64 (+ (* vertices gd-max-degree) 2))]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (gd-build offsets targets weights vertices 1)
      (while (< round rounds)
        (begin
          (set!
            acc
            (%
              (+
                (* acc 31)
                (gd-dijkstra
                  offsets
                  targets
                  weights
                  dist
                  settled
                  heap-key
                  heap-node
                  vertices
                  (% round vertices)))
              gd-modulus))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [vertices : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (gd-bench vertices rounds))
      0)))