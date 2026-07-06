;; compiler_parallel_move.tl - target-neutral parallel move graph decisions.
;; A move edge writes one logical destination and reads one logical source. Each
;; side may occupy up to two resources so register-pair/group moves can block on
;; either half without teaching this helper about registers, stack slots, or IR
;; values. Resource id 0 means "no resource".
(defenum CompilerParallelMoveEdge
  (ParallelMoveEdge i64 i64 i64 i64 i64))

(defenum CompilerParallelMoveEdgeList
  (CompilerParallelMoveNil)
  (CompilerParallelMoveCons
    CompilerParallelMoveEdge
    (Box CompilerParallelMoveEdgeList)))

(defenum CompilerParallelMoveDecision
  (CompilerParallelMoveDone)
  (CompilerParallelMoveUnblocked i64)
  (CompilerParallelMoveCycle i64))

(define (compiler-parallel-move-edge-cons
  [edge : CompilerParallelMoveEdge]
  [rest : CompilerParallelMoveEdgeList]) : CompilerParallelMoveEdgeList
  (CompilerParallelMoveCons edge (box rest)))

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

(define (compiler-parallel-move-edge-list-source-uses-resource?
  [edges : CompilerParallelMoveEdgeList]
  [resource : i64]
  [exclude-id : i64]) : bool
  (match edges
    [(CompilerParallelMoveNil) false]
    [(CompilerParallelMoveCons edge rest)
      (if (and
        (not (= (compiler-parallel-move-edge-id edge) exclude-id))
        (compiler-parallel-move-edge-source-uses-resource? edge resource))
        true
        (compiler-parallel-move-edge-list-source-uses-resource?
          (box-get rest)
          resource
          exclude-id))]))

(define (compiler-parallel-move-edge-blocked?
  [edge : CompilerParallelMoveEdge]
  [blockers : CompilerParallelMoveEdgeList]) : bool
  (match edge
    [(ParallelMoveEdge id dest0 dest1 _ _)
      (or
        (compiler-parallel-move-edge-list-source-uses-resource?
          blockers
          dest0
          id)
        (compiler-parallel-move-edge-list-source-uses-resource?
          blockers
          dest1
          id))]))

(define (compiler-parallel-move-list-has-blocked?
  [edges : CompilerParallelMoveEdgeList]
  [blockers : CompilerParallelMoveEdgeList]) : bool
  (match edges
    [(CompilerParallelMoveNil) false]
    [(CompilerParallelMoveCons edge rest)
      (if (compiler-parallel-move-edge-blocked? edge blockers)
        true
        (compiler-parallel-move-list-has-blocked? (box-get rest) blockers))]))

(define (compiler-parallel-move-find-unblocked
  [remaining : CompilerParallelMoveEdgeList]
  [blockers : CompilerParallelMoveEdgeList]) : CompilerParallelMoveDecision
  (match remaining
    [(CompilerParallelMoveNil) CompilerParallelMoveDone]
    [(CompilerParallelMoveCons edge rest)
      (if (compiler-parallel-move-edge-blocked? edge blockers)
        (compiler-parallel-move-find-unblocked (box-get rest) blockers)
        (CompilerParallelMoveUnblocked (compiler-parallel-move-edge-id edge)))]))

(define (compiler-parallel-move-decision
  [remaining : CompilerParallelMoveEdgeList]
  [blockers : CompilerParallelMoveEdgeList]) : CompilerParallelMoveDecision
  (match remaining
    [(CompilerParallelMoveNil) CompilerParallelMoveDone]
    [(CompilerParallelMoveCons first _)
      (match (compiler-parallel-move-find-unblocked remaining blockers)
        [(CompilerParallelMoveUnblocked id) (CompilerParallelMoveUnblocked id)]
        [(CompilerParallelMoveCycle id) (CompilerParallelMoveCycle id)]
        [(CompilerParallelMoveDone)
          (CompilerParallelMoveCycle (compiler-parallel-move-edge-id first))])]))

(define (compiler-parallel-move-test-edge
  [id : i64]
  [dest : i64]
  [source : i64]) : CompilerParallelMoveEdge
  (ParallelMoveEdge id dest 0 source 0))

(define (compiler-parallel-move-self-test?) : bool
  (let
    [empty : CompilerParallelMoveEdgeList CompilerParallelMoveNil]
    [chain : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (compiler-parallel-move-test-edge 1 10 20)
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge 2 20 0)
          CompilerParallelMoveNil))]
    [cycle : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (compiler-parallel-move-test-edge 1 10 20)
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge 2 20 10)
          CompilerParallelMoveNil))]
    [pair : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (ParallelMoveEdge 3 12 13 14 15)
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge 4 8 13)
          CompilerParallelMoveNil))]
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
      (compiler-parallel-move-list-has-blocked? pair pair))))