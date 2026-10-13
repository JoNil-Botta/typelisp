;; Global-write reachability over the checked program's call graph.
(import stdlib.vector)
(import stdlib.hashmap)
(import stdlib.iterator)
(import (hashmap.hashmap i64 i64) as ids)

;; Graph storage uses only construction, indexed reads and append.
(import (vector.vector i64 core) as words)

(defstruct Edge
  (node i64)
  (next i64))

(defstruct Graph
  ;; Reverse call edges let one query propagate a global's writers to every
  ;; caller. Cached witness successors always decrease the propagation depth,
  ;; including inside recursive SCCs; absence is published only at fixpoint.
  (callers (__tl_dyn-array i64))
  ;; Every nonempty reverse adjacency occurs once in this sparse index.
  (callee-nodes words.Vec)
  (links words.Vec)
  (writers ids.Map)
  (summaries ids.Map)
  (indirect i64))

(define (new [node-count : i64]) : Graph
  (Graph
    (__tl_make-array i64 (+ node-count 1))
    (words.new)
    (words.with-capacity 8)
    (ids.with-capacity 0)
    (ids.with-capacity 0)
    node-count))

;; Retained edges never point into the source collector's scratch arena.
(define (append! [out : (&mut out Graph)] [source : (& source Graph)]) : unit
  (when (= (words.len (& source.links)) 0) (return unit))
  (for [index (iterator.range 0 (words.len (& source.callee-nodes)))]
    (let
      [callee : i64 (words.get (& source.callee-nodes) index 0)]
      [head : i64 (array-ref source.callers callee)]
      (while (!= head 0)
        (let
          [edge : Edge (link-at (& source.links) (- head 1))]
          (add-call! out edge.node callee)
          (set! head edge.next)))))
  (for [index (iterator.range 0 (ids.capacity (& source.writers)))]
    (match (ids.entry-at (& source.writers) index)
      [(EntrySome global head)
        (while (!= head 0)
          (let
            [edge : Edge (link-at (& source.links) (- head 1))]
            (add-write! out edge.node global)
            (set! head edge.next)))]
      [_ unit])))

;; Link handles are one-based logical indices; storage holds two full-width
;; words per link. Bounds are checked before doubling an arbitrary index.
(define (link-at [links : (& links words.Vec)] [index : i64]) : Edge
  (if (or (< index 0) (>= index (/ (words.len links) 2)))
    (Edge 0 0)
    (let
      [word : i64 (* index 2)]
      (Edge (words.get links word 0) (words.get links (+ word 1) 0)))))

(define (link! [graph : (&mut graph Graph)] [node : i64] [next : i64]) : i64
  (words.push-ref! (&mut graph.links) node)
  (words.push-ref! (&mut graph.links) next)
  (/ (words.len (& graph.links)) 2))

(define (add-call! [graph : (&mut graph Graph)] [caller : i64] [callee : i64]) : unit
  (ids.clear-ref! (&mut graph.summaries))
  (let
    [head : i64 (array-ref graph.callers callee)]
    (when (= head 0) (words.push-ref! (&mut graph.callee-nodes) callee))
    (let
      [next : i64 (link! graph caller head)]
      (set! (array-ref graph.callers callee) next))))

(define (add-write!
  [graph : (&mut graph Graph)]
  [function : i64]
  [global : i64]) : unit
  (ids.clear-ref! (&mut graph.summaries))
  (let
    [head : i64 (ids.get-value-or (& graph.writers) global 0)]
    [next : i64 (link! graph function head)]
    (ids.insert-ref! (&mut graph.writers) global next)))

(define (summary! [graph : (&mut graph Graph)] [global : i64]) : (__tl_dyn-array
    i64)
  (let
    [cached : i64 (ids.get-value-or (& graph.summaries) global 0)]
    (if (!= cached 0)
      (unsafe
        (ptr-read (int->ptr (cast cached : u64) : (Ptr (__tl_dyn-array i64)))))
      (let
        [result : (__tl_dyn-array i64)
          (__tl_make-array i64 (array-length graph.callers))]
        [queue : words.Vec (words.new)]
        [cursor : i64 (ids.get-value-or (& graph.writers) global 0)]
        (while (!= cursor 0)
          (let
            [edge : Edge (link-at (& graph.links) (- cursor 1))]
            [node : i64 edge.node]
            (when
              (= (array-ref result node) 0)
              ;; -1 ends the witness at a direct writer.
              (set! (array-ref result node) -1)
              (words.push-ref! (&mut queue) node))
            (set! cursor edge.next)))
        (let
          [index : i64 0]
          (while (< index (words.len (& queue)))
            (let
              [callee : i64 (words.get (& queue) index 0)]
              [head : i64 (array-ref graph.callers callee)]
              (while (!= head 0)
                (let
                  [edge : Edge (link-at (& graph.links) (- head 1))]
                  [caller : i64 edge.node]
                  (when
                    (= (array-ref result caller) 0)
                    (set! (array-ref result caller) (+ callee 1))
                    (words.push-ref! (&mut queue) caller))
                  (set! head edge.next)))
              (+= index 1))))
        (let
          [cell : (__tl_dyn-array (__tl_dyn-array i64))
            (__tl_make-array (__tl_dyn-array i64) 1)]
          [address : i64
            (unsafe
              (cast (ptr->int (__tl_array-data cell)) : i64))]
          (set! (array-ref cell 0) result)
          (ids.insert-ref! (&mut graph.summaries) global address))
        result))))

(define (witness! [graph : (&mut graph Graph)] [callee : i64] [global : i64]) : words.Vec
  ;; No call path can write a global without a direct writer. Recheck this
  ;; sparse index on every query so adding a writer still invalidates absence.
  (when
    (= (ids.get-value-or (& graph.writers) global 0) 0)
    (return (words.new)))
  (let
    [summary : (__tl_dyn-array i64) (summary! graph global)]
    [path : words.Vec (words.new)]
    [node : i64 callee]
    (while (and (>= node 0) (!= (array-ref summary node) 0))
      (words.push-ref! (&mut path) node)
      (set! node (- (array-ref summary node) 1)))
    path))