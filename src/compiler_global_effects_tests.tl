(import compiler_global_effects as effects)
(import stdlib.vector)
(import (vector.vector i64 core) as words)
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
            [graph : effects.Graph (effects.new 3)]
            [reachable : i64 writers]
            (effects.append! (&mut graph) (& base))
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

(test
  global-effects-link-storage-full-width-and-growth
  (let
    [graph : effects.Graph (effects.new 0)]
    [first : i64
      (effects.link! (&mut graph) 9223372036854775807 9223372036854775807)]
    (test.assert-i64-eq first 1 "link handles start at one")
    (for [index (iterator.range 0 64)]
      (test.assert-i64-eq
        (effects.link! (&mut graph) (+ 4294967296 index) first)
        (+ index 2)
        "growth preserves logical link handles"))
    (let
      [saved : effects.Edge (effects.link-at (& graph.links) (- first 1))]
      [last : effects.Edge (effects.link-at (& graph.links) 64)]
      (test.assert-i64-eq
        saved.node
        9223372036854775807
        "retained node keeps its full-width ID")
      (test.assert-i64-eq
        saved.next
        9223372036854775807
        "retained successor keeps its full-width ID")
      (test.assert-i64-eq
        last.node
        4294967359
        "growth preserves later full-width IDs")
      (test.assert-i64-eq last.next first "growth preserves successor handles"))
    (for [case (iterator.range 0 4)]
      (let
        [index : i64
          (cond
            [(= case 0) -1]
            [(= case 1) 65]
            [(= case 2) 9223372036854775807]
            [else (- -9223372036854775807 1)])]
        [missing : effects.Edge (effects.link-at (& graph.links) index)]
        (test.assert-i64-eq
          missing.node
          0
          "invalid link indices return the fallback before offset arithmetic")
        (test.assert-i64-eq
          missing.next
          0
          "invalid link successor uses the same fallback")))))

(test
  global-effects-wide-global-through-grown-sparse-links
  (let
    [graph : effects.Graph (effects.new 131)]
    (for [index (iterator.range 66 130)]
      (effects.add-call! (&mut graph) index index))
    (effects.add-call! (&mut graph) 130 65)
    (effects.add-call! (&mut graph) 65 0)
    (effects.add-write! (&mut graph) 0 9223372036854775807)
    (let
      [path : words.Vec (effects.witness! (&mut graph) 130 9223372036854775807)]
      (test.assert-i64-eq
        (words.len (& path))
        3
        "sparse high-index callers reach the full-width global")
      (test.assert-i64-eq
        (words.get (& path) 0 -1)
        130
        "witness starts at the high-index caller")
      (test.assert-i64-eq
        (words.get (& path) 2 -1)
        0
        "witness ends at the writer")
      (test.assert-i64-eq
        (words.len (& (effects.witness! (&mut graph) 130 9223372036854775806)))
        0
        "adjacent full-width global identities remain distinct"))))