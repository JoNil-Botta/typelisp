;; compiler_parallel_move.tl - target-neutral parallel move graph decisions.
;; A move edge writes one logical destination and reads one logical source. Each
;; side may occupy up to two resources so register-pair/group moves can block on
;; either half without teaching this helper about registers, stack slots, or IR
;; values. Resource id 0 means "no resource".
(defenum CompilerParallelMoveEdge
  (ParallelMoveEdge i64 i64 i64 i64 i64))

(defstruct CompilerParallelMoveEdgeSeq
  (slots (Array CompilerParallelMoveEdge))
  (len i64))

(defenum CompilerParallelMoveDecision
  (CompilerParallelMoveDone)
  (CompilerParallelMoveUnblocked i64)
  (CompilerParallelMoveCycle i64))

(define (compiler-parallel-move-edge-seq-empty) : CompilerParallelMoveEdgeSeq
  (CompilerParallelMoveEdgeSeq (make-array CompilerParallelMoveEdge 0) 0))

(define (compiler-parallel-move-edge-seq-with-capacity [capacity : i64]) : CompilerParallelMoveEdgeSeq
  (CompilerParallelMoveEdgeSeq (make-array CompilerParallelMoveEdge capacity) 0))

(define (compiler-parallel-move-edge-seq-copy-range!
  [dst : (&mut dst (Array CompilerParallelMoveEdge))]
  [src : (& src (Array CompilerParallelMoveEdge))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-parallel-move-edge-push!
  [seq : (&mut seq CompilerParallelMoveEdgeSeq)]
  [edge : CompilerParallelMoveEdge]) : unit
  (begin
    (if (< (struct-get seq len) (array-length (struct-get seq slots)))
      unit
      (let
        [old-capacity : i64 (array-length (struct-get seq slots))]
        [bigger : (Array CompilerParallelMoveEdge)
          (make-array
            CompilerParallelMoveEdge
            (if (< old-capacity 1)
              4
              (* old-capacity 2)))]
        (begin
          (compiler-parallel-move-edge-seq-copy-range!
            (&mut bigger)
            (& (struct-get seq slots))
            (struct-get seq len))
          (set! (struct-get seq slots) bigger))))
    (let
      [index : i64 (struct-get seq len)]
      (begin
        (array-set! (struct-get seq slots) index edge)
        (set! (struct-get seq len) (+ index 1))))))

(define (compiler-parallel-move-edge-id [edge : CompilerParallelMoveEdge]) : i64
  (match edge
    [(ParallelMoveEdge id _ _ _ _) id]))

(define (compiler-parallel-move-resource-eq? [left : i64] [right : i64]) : bool
  (and (not (= left 0)) (= left right)))

(define (compiler-parallel-move-edge-source-uses-resource?
  [edge : CompilerParallelMoveEdge]
  [resource : i64]) : bool
  (match edge
    [(ParallelMoveEdge _ _ _ source0 source1)
      (or
        (compiler-parallel-move-resource-eq? source0 resource)
        (compiler-parallel-move-resource-eq? source1 resource))]))

(define (compiler-parallel-move-edge-seq-source-uses-resource?
  [edges : CompilerParallelMoveEdgeSeq]
  [resource : i64]
  [exclude-id : i64]) : bool
  (let
    [slots : (Array CompilerParallelMoveEdge) (struct-get edges slots)]
    [count : i64 (struct-get edges len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [edge : CompilerParallelMoveEdge (array-ref slots index)]
          (begin
            (when
              (and
                (not (= (compiler-parallel-move-edge-id edge) exclude-id))
                (compiler-parallel-move-edge-source-uses-resource?
                  edge
                  resource))
              (return true))
            (set! index (+ index 1)))))
      false)))

(define (compiler-parallel-move-edge-blocked?
  [edge : CompilerParallelMoveEdge]
  [blockers : CompilerParallelMoveEdgeSeq]) : bool
  (match edge
    [(ParallelMoveEdge id dest0 dest1 _ _)
      (or
        (compiler-parallel-move-edge-seq-source-uses-resource?
          blockers
          dest0
          id)
        (compiler-parallel-move-edge-seq-source-uses-resource?
          blockers
          dest1
          id))]))

(define (compiler-parallel-move-seq-has-blocked?
  [edges : CompilerParallelMoveEdgeSeq]
  [blockers : CompilerParallelMoveEdgeSeq]) : bool
  (let
    [slots : (Array CompilerParallelMoveEdge) (struct-get edges slots)]
    [count : i64 (struct-get edges len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (when
            (compiler-parallel-move-edge-blocked?
              (array-ref slots index)
              blockers)
            (return true))
          (set! index (+ index 1))))
      false)))

(define (compiler-parallel-move-find-unblocked
  [remaining : CompilerParallelMoveEdgeSeq]
  [blockers : CompilerParallelMoveEdgeSeq]) : CompilerParallelMoveDecision
  (let
    [slots : (Array CompilerParallelMoveEdge) (struct-get remaining slots)]
    [count : i64 (struct-get remaining len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [edge : CompilerParallelMoveEdge (array-ref slots index)]
          (begin
            (when
              (not (compiler-parallel-move-edge-blocked? edge blockers))
              (return
                (CompilerParallelMoveUnblocked
                  (compiler-parallel-move-edge-id edge))))
            (set! index (+ index 1)))))
      CompilerParallelMoveDone)))

(define (compiler-parallel-move-decision
  [remaining : CompilerParallelMoveEdgeSeq]
  [blockers : CompilerParallelMoveEdgeSeq]) : CompilerParallelMoveDecision
  (if (= (struct-get remaining len) 0)
    CompilerParallelMoveDone
    (match (compiler-parallel-move-find-unblocked remaining blockers)
      [(CompilerParallelMoveUnblocked id) (CompilerParallelMoveUnblocked id)]
      [(CompilerParallelMoveCycle id) (CompilerParallelMoveCycle id)]
      [(CompilerParallelMoveDone)
        (CompilerParallelMoveCycle
          (compiler-parallel-move-edge-id
            (array-ref (struct-get remaining slots) 0)))])))

(define (compiler-parallel-move-test-edge
  [id : i64]
  [dest : i64]
  [source : i64]) : CompilerParallelMoveEdge
  (ParallelMoveEdge id dest 0 source 0))

(define (compiler-parallel-move-test-seq-two
  [first : CompilerParallelMoveEdge]
  [second : CompilerParallelMoveEdge]) : CompilerParallelMoveEdgeSeq
  (let
    [edges : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-edge-seq-with-capacity 2)]
    (begin
      (compiler-parallel-move-edge-push! (&mut edges) first)
      (compiler-parallel-move-edge-push! (&mut edges) second)
      edges)))

(define (compiler-parallel-move-self-test?) : bool
  (let
    [empty : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-edge-seq-empty)]
    [chain : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-test-seq-two
        (compiler-parallel-move-test-edge 1 10 20)
        (compiler-parallel-move-test-edge 2 20 0))]
    [cycle : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-test-seq-two
        (compiler-parallel-move-test-edge 1 10 20)
        (compiler-parallel-move-test-edge 2 20 10))]
    [pair : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-test-seq-two
        (ParallelMoveEdge 3 12 13 14 15)
        (compiler-parallel-move-test-edge 4 8 13))]
    ;; A scalar destination must not clobber either half of a pair source
    ;; before the pair is copied. This is the reverse of `pair` above and is
    ;; the phi-carried group case: emit edge 5 first, then edge 6 may write
    ;; resource 12.
    [pair-source : CompilerParallelMoveEdgeSeq
      (compiler-parallel-move-test-seq-two
        (ParallelMoveEdge 5 8 0 12 13)
        (compiler-parallel-move-test-edge 6 12 20))]
    (and
      (match (compiler-parallel-move-decision empty empty)
        [(CompilerParallelMoveDone) true]
        [_ false])
      (match (compiler-parallel-move-decision chain chain)
        [(CompilerParallelMoveUnblocked id) (= id 1)]
        [_ false])
      (match (compiler-parallel-move-decision cycle cycle)
        [(CompilerParallelMoveCycle id) (= id 1)]
        [_ false])
      (match (compiler-parallel-move-decision pair pair)
        [(CompilerParallelMoveUnblocked id) (= id 4)]
        [_ false])
      (compiler-parallel-move-seq-has-blocked? pair pair)
      (match (compiler-parallel-move-decision pair-source pair-source)
        [(CompilerParallelMoveUnblocked id) (= id 5)]
        [_ false])
      (compiler-parallel-move-seq-has-blocked? pair-source pair-source))))