;; compiler_parallel_move.tl - target-neutral parallel move graph decisions.
;; A move edge writes one logical destination and reads one logical source. Each
;; side may occupy up to two resources so register-pair/group moves can block on
;; either half without teaching this helper about registers, stack slots, or IR
;; values. Resource id 0 means "no resource".
(import compiler_owned_view as owned_view)

(defmacro (compiler-parallel-move-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defenum CompilerParallelMoveEdge
  (ParallelMoveEdge i64 i64 i64 i64 i64))

(defstruct CompilerParallelMoveEdgeSeq
  (slots (__tl_dyn-array CompilerParallelMoveEdge))
  (len i64))

(defenum CompilerParallelMoveDecision
  (CompilerParallelMoveDone)
  (CompilerParallelMoveUnblocked i64)
  (CompilerParallelMoveCycle i64))

(define (compiler-parallel-move-edge-seq-with-capacity [capacity : i64]) : CompilerParallelMoveEdgeSeq
  (CompilerParallelMoveEdgeSeq
    (__tl_make-array CompilerParallelMoveEdge capacity)
    0))

(define (compiler-parallel-move-edge-seq-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerParallelMoveEdge))]
  [src : (& src (__tl_dyn-array CompilerParallelMoveEdge))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-parallel-move-edge-push!
  [seq : (&mut seq CompilerParallelMoveEdgeSeq)]
  [edge : CompilerParallelMoveEdge]) : unit
  (begin
    (if (< seq.len (array-length seq.slots))
      unit
      (let
        [old-capacity : i64 (array-length seq.slots)]
        [bigger : (__tl_dyn-array CompilerParallelMoveEdge)
          (__tl_make-array
            CompilerParallelMoveEdge
            (if (< old-capacity 1)
              4
              (* old-capacity 2)))]
        (begin
          (compiler-parallel-move-edge-seq-copy-range!
            (&mut bigger)
            (& seq.slots)
            seq.len)
          (set! seq.slots bigger))))
    (let
      [index : i64 seq.len]
      (begin
        (set! (array-ref seq.slots index) edge)
        (set! seq.len (+ index 1))))))

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
    [slots : (__tl_dyn-array CompilerParallelMoveEdge) edges.slots]
    [count : i64 edges.len]
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
          (compiler-parallel-move-shared-view blockers)
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
    [slots : (__tl_dyn-array CompilerParallelMoveEdge) edges.slots]
    [count : i64 edges.len]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (when
            (compiler-parallel-move-edge-blocked?
              (array-ref slots index)
              (compiler-parallel-move-shared-view blockers))
            (return true))
          (set! index (+ index 1))))
      false)))

(define (compiler-parallel-move-find-unblocked
  [remaining : CompilerParallelMoveEdgeSeq]
  [blockers : CompilerParallelMoveEdgeSeq]) : CompilerParallelMoveDecision
  (let
    [slots : (__tl_dyn-array CompilerParallelMoveEdge) remaining.slots]
    [count : i64 remaining.len]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [edge : CompilerParallelMoveEdge (array-ref slots index)]
          (begin
            (when
              (not
                (compiler-parallel-move-edge-blocked?
                  edge
                  (compiler-parallel-move-shared-view blockers)))
              (return
                (CompilerParallelMoveUnblocked
                  (compiler-parallel-move-edge-id edge))))
            (set! index (+ index 1)))))
      CompilerParallelMoveDone)))

(define (compiler-parallel-move-decision
  [remaining : (& remaining CompilerParallelMoveEdgeSeq)]
  [blockers : (& blockers CompilerParallelMoveEdgeSeq)]) : CompilerParallelMoveDecision
  (let
    [remaining : CompilerParallelMoveEdgeSeq
      (owned_view.compiler-owned-reference-shared-view remaining)]
    [blockers : CompilerParallelMoveEdgeSeq
      (owned_view.compiler-owned-reference-shared-view blockers)]
    (if (= remaining.len 0)
      CompilerParallelMoveDone
      (match (compiler-parallel-move-find-unblocked
        (compiler-parallel-move-shared-view remaining)
        blockers)
        [(CompilerParallelMoveUnblocked id) (CompilerParallelMoveUnblocked id)]
        [(CompilerParallelMoveCycle id) (CompilerParallelMoveCycle id)]
        [(CompilerParallelMoveDone)
          (CompilerParallelMoveCycle
            (compiler-parallel-move-edge-id (array-ref remaining.slots 0)))]))))