(import compiler_global_effects as effects)
(import stdlib.vector)
(import (vector.vector i64) as words)
(import stdlib.test)
(import stdlib.iterator)

(test
  global-effects-recursive-witness
  (let
    [graph : effects.Graph (effects.new 8)]
    (effects.add-call! (&mut graph) 0 1)
    (effects.add-call! (&mut graph) 1 2)
    (effects.add-call! (&mut graph) 2 1)
    (effects.add-call! (&mut graph) 2 3)
    (effects.add-write! (&mut graph) 3 7)
    (let
      [path : words.Vec (effects.witness! (&mut graph) 0 7)]
      (test.assert-i64-eq
        (words.len (& path))
        4
        "recursive path reaches the writer")
      (test.assert-i64-eq
        (words.get (& path) 0 -1)
        0
        "starts at the called function")
      (test.assert-i64-eq
        (words.get (& path) 3 -1)
        3
        "ends at the direct writer"))
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 0 6)))
      0
      "a different global has no write effect")
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 4 7)))
      0
      "an unreachable writer has no effect")))

(test
  global-effects-indirect-union-and-cache-invalidation
  (let
    [graph : effects.Graph (effects.new 65)]
    (effects.add-call! (&mut graph) 0 graph.indirect)
    (effects.add-call! (&mut graph) graph.indirect 64)
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 0 7)))
      0
      "an empty summary is a completed fixpoint")
    (effects.add-write! (&mut graph) 64 7)
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 0 7)))
      3
      "new writes invalidate the previous empty summary")
    (effects.add-call! (&mut graph) 63 0)
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 63 7)))
      4
      "new callers invalidate the previous positive summary")))

(test
  global-effects-nonwriting-cycle
  (let
    [graph : effects.Graph (effects.new 3)]
    (effects.add-call! (&mut graph) 0 1)
    (effects.add-call! (&mut graph) 1 0)
    (effects.add-call! (&mut graph) 1 1)
    (effects.add-write! (&mut graph) 2 9)
    (test.assert-i64-eq
      (words.len (& (effects.witness! (&mut graph) 0 9)))
      0
      "a recursive SCC cannot reach an unrelated writer")))

(test
  global-effects-exhaustive-three-node-graphs
  ;; All directed three-node graphs, including self edges and every writer
  ;; subset, agree with an independent bounded reachability oracle.
  (for [mask (iterator.range 0 512)]
    (let
      [base : effects.Graph (effects.new 3)]
      (for [caller (iterator.range 0 3)]
        (for [callee (iterator.range 0 3)]
          (when
            (!= (bit-and mask (shl 1 (+ (* caller 3) callee))) 0)
            (effects.add-call! (&mut base) caller callee))))
      (for [writers (iterator.range 0 8)]
        (with-arena
          scratch
          (let
            [graph : effects.Graph (effects.copy (& base))]
            [reachable : i64 writers]
            (for [node (iterator.range 0 3)]
              (when
                (!= (bit-and writers (shl 1 node)) 0)
                (effects.add-write! (&mut graph) node 7)))
            (for [round (iterator.range 0 3)]
              (for [caller (iterator.range 0 3)]
                (for [callee (iterator.range 0 3)]
                  (when
                    (and
                      (!= (bit-and mask (shl 1 (+ (* caller 3) callee))) 0)
                      (!= (bit-and reachable (shl 1 callee)) 0))
                    (set! reachable (bit-or reachable (shl 1 caller)))))))
            (for [caller (iterator.range 0 3)]
              (let
                [path : words.Vec (effects.witness! (&mut graph) caller 7)]
                [n : i64 (words.len (& path))]
                (test.assert-bool-eq
                  (> n 0)
                  (!= (bit-and reachable (shl 1 caller)) 0)
                  "write summary agrees with bounded reachability")
                (test.assert-true (<= n 3) "witness cannot loop through an SCC")
                (when
                  (> n 0)
                  (test.assert-true
                    (!=
                      (bit-and writers (shl 1 (words.get (& path) (- n 1) -1)))
                      0)
                    "witness ends at a direct writer")
                  (for [index (iterator.range 1 n)]
                    (test.assert-true
                      (!=
                        (bit-and
                          mask
                          (shl
                            1
                            (+
                              (* (words.get (& path) (- index 1) -1) 3)
                              (words.get (& path) index -1))))
                        0)
                      "every witness step is an actual call edge")))))))))))