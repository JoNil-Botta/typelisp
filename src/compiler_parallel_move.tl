;; compiler_parallel_move.tl - target-neutral parallel move graph decisions.
(import stdlib.string)

;; A move edge writes one logical destination and reads one logical source. Each
;; side may occupy up to two resources so register-pair/group moves can block on
;; either half without teaching this helper about registers, stack slots, or IR
;; values. The empty string means "no resource".
(defenum CompilerParallelMoveEdge
  (ParallelMoveEdge String String String String String))

(defenum CompilerParallelMoveEdgeList
  (CompilerParallelMoveNil)
  (CompilerParallelMoveCons
    CompilerParallelMoveEdge
    (Box CompilerParallelMoveEdgeList)))

(defenum CompilerParallelMoveDecision
  (CompilerParallelMoveDone)
  (CompilerParallelMoveUnblocked String)
  (CompilerParallelMoveCycle String))

(define (compiler-parallel-move-edge-cons
  [edge : CompilerParallelMoveEdge]
  [rest : CompilerParallelMoveEdgeList]) : CompilerParallelMoveEdgeList
  (CompilerParallelMoveCons edge (box rest)))

(define (compiler-parallel-move-edge-id [edge : CompilerParallelMoveEdge]) : String
  (match edge
    [(ParallelMoveEdge id _ _ _ _) id]))

(define (compiler-parallel-move-resource-eq? [left : String] [right : String]) : bool
  (and (not (string.eq left "")) (string.eq left right)))

(define (compiler-parallel-move-edge-source-uses-resource?
  [edge : CompilerParallelMoveEdge]
  [resource : String]) : bool
  (match edge
    [(ParallelMoveEdge _ _ _ source0 source1)
      (or
        (compiler-parallel-move-resource-eq? source0 resource)
        (compiler-parallel-move-resource-eq? source1 resource))]))

(define (compiler-parallel-move-edge-list-source-uses-resource?
  [edges : CompilerParallelMoveEdgeList]
  [resource : String]
  [exclude-id : String]) : bool
  (match edges
    [(CompilerParallelMoveNil) false]
    [(CompilerParallelMoveCons edge rest)
      (if (and
        (not (string.eq (compiler-parallel-move-edge-id edge) exclude-id))
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
  [id : String]
  [dest : String]
  [source : String]) : CompilerParallelMoveEdge
  (ParallelMoveEdge id dest "" source ""))

(define (compiler-parallel-move-self-test?) : bool
  (let
    [empty : CompilerParallelMoveEdgeList CompilerParallelMoveNil]
    [chain : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (compiler-parallel-move-test-edge "a" "r1" "r2")
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge "b" "r2" "")
          CompilerParallelMoveNil))]
    [cycle : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (compiler-parallel-move-test-edge "a" "r1" "r2")
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge "b" "r2" "r1")
          CompilerParallelMoveNil))]
    [pair : CompilerParallelMoveEdgeList
      (compiler-parallel-move-edge-cons
        (ParallelMoveEdge "pair" "r12" "r13" "r14" "r15")
        (compiler-parallel-move-edge-cons
          (compiler-parallel-move-test-edge "half" "r8" "r13")
          CompilerParallelMoveNil))]
    (and
      (match (compiler-parallel-move-decision empty empty)
        [(CompilerParallelMoveDone) true]
        [_ false])
      (match (compiler-parallel-move-decision chain chain)
        [(CompilerParallelMoveUnblocked id) (string.eq id "a")]
        [_ false])
      (match (compiler-parallel-move-decision cycle cycle)
        [(CompilerParallelMoveCycle id) (string.eq id "a")]
        [_ false])
      (match (compiler-parallel-move-decision pair pair)
        [(CompilerParallelMoveUnblocked id) (string.eq id "half")]
        [_ false])
      (compiler-parallel-move-list-has-blocked? pair pair))))