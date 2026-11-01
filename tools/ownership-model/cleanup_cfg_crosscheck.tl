;; Bounded CFG correspondence for independent concrete cleanup executions.
;; Five authored graphs, loop iteration counts 0..3 and both branch outcomes.
;; This is finite regression evidence, not a proof for arbitrary source CFGs.
;; Static production cleanup actions are projected along each concrete path;
;; rejected traces also compare their successful prefix, terminated by Abort.
;; Only cleanup_model decides expected acceptance and exact cleanup sequence.
(import cleanup_model as model)
(import cleanup_crosscheck as linear)
(import compiler_ownership_core as core)
(import stdlib.io)
(import stdlib.string)

(defstruct Point
  (block i64)
  (instruction i64))

(defstruct Path
  (events (__tl_dyn-array model.Event))
  (points (__tl_dyn-array Point)))

(define (source [block : i64] [instruction : i64]) : core.OwnershipSource
  (core.OwnershipSource
    "cleanup-cfg-case.tl"
    (+ 1 (+ (* block 16) instruction))
    1
    "cleanup CFG point"))

(define (instruction
  [operation : core.OwnershipOperation]
  [block : i64]
  [index : i64]) : core.OwnershipInstruction
  (core.OwnershipInstruction operation (source block index)))

(define (modes [family : i64]) : (Array model.Mode 2)
  (array
    (if (>= family 3)
      model.Mode.Discharge
      model.Mode.Automatic)
    model.Mode.Automatic))

(define (body [family : i64]) : core.OwnershipBody
  (let
    [types : (__tl_dyn-array core.OwnershipType) (linear.types)]
    [locals : (__tl_dyn-array core.OwnershipLocal) (linear.locals)]
    [places : (__tl_dyn-array core.OwnershipPlace) (linear.places)]
    [blocks : (__tl_dyn-array core.OwnershipBlock)
      (__tl_make-array core.OwnershipBlock 4)]
    [obligations : (__tl_dyn-array core.OwnershipObligation)
      (__tl_make-array
        (core.OwnershipObligation
          core.OwnershipObligationParent.Root
          (linear.place 0)
          (if (>= family 3)
            core.OwnershipObligationMode.Discharge
            core.OwnershipObligationMode.AutomaticRequired)
          (linear.cleanup 1)
          (__tl_make-array core.OwnershipCleanupUse 0)
          (source 0 0))
        (core.OwnershipObligation
          (core.OwnershipObligationParent.Parent (linear.obligation 0))
          (linear.place 3)
          core.OwnershipObligationMode.AutomaticRequired
          (linear.cleanup 1)
          (__tl_make-array core.OwnershipCleanupUse 0)
          (source 2 0)))]
    (begin
      (__tl_array-push!
        types
        (core.OwnershipType core.OwnershipTypeKind.Boolean true))
      (__tl_array-push!
        locals
        (core.OwnershipLocal (linear.type-id 2) true (source 0 0)))
      (__tl_array-push!
        places
        (core.OwnershipPlace
          (core.OwnershipLocalId (linear.id) 2)
          (linear.type-id 2)
          core.OwnershipProjection.Root
          (source 0 0)))
      (set!
        (array-ref blocks 0)
        (core.OwnershipBlock
          (__tl_make-array
            (instruction
              (core.OwnershipOperation.BindFresh (linear.obligation 0))
              0
              0))
          (if (< family 3)
            (core.OwnershipTerminator.Goto (linear.block 1))
            (core.OwnershipTerminator.Branch
              (linear.place 6)
              (linear.block 1)
              (linear.block 2)))
          (source 0 1)))
      (if (< family 3)
        (begin
          (set!
            (array-ref blocks 1)
            (core.OwnershipBlock
              ;; An ordinary Copy evaluation supplies a new unknown Boolean
              ;; on each header visit; finite exit choices are actual paths.
              (__tl_make-array
                (instruction
                  (core.OwnershipOperation.Assign (linear.place 6))
                  1
                  0))
              (core.OwnershipTerminator.Branch
                (linear.place 6)
                (linear.block 2)
                (linear.block 3))
              (source 1 1)))
          (let
            [instructions : (__tl_dyn-array core.OwnershipInstruction)
              (__tl_make-array
                core.OwnershipInstruction
                (if (= family 1)
                  1
                  2))]
            (begin
              (set!
                (array-ref instructions 0)
                (instruction
                  (if (= family 2)
                    (core.OwnershipOperation.BindFresh (linear.obligation 1))
                    (core.OwnershipOperation.Cleanup
                      (linear.obligation 0)
                      (linear.cleanup 1)))
                  2
                  0))
              (unless
                (= family 1)
                (set!
                  (array-ref instructions 1)
                  (instruction
                    (if (= family 2)
                      (core.OwnershipOperation.Leave (linear.obligation 1))
                      (core.OwnershipOperation.Initialize (linear.place 0)))
                    2
                    1)))
              (set!
                (array-ref blocks 2)
                (core.OwnershipBlock
                  instructions
                  (core.OwnershipTerminator.Goto (linear.block 1))
                  (source
                    2
                    (if (= family 1)
                      1
                      2)))))))
        (begin
          (set!
            (array-ref blocks 1)
            (core.OwnershipBlock
              (__tl_make-array
                (instruction
                  (core.OwnershipOperation.Cleanup
                    (linear.obligation 0)
                    (linear.cleanup 1))
                  1
                  0))
              (core.OwnershipTerminator.Goto (linear.block 3))
              (source 1 1)))
          (let
            [instructions : (__tl_dyn-array core.OwnershipInstruction)
              (__tl_make-array
                core.OwnershipInstruction
                (if (= family 3)
                  1
                  0))]
            (begin
              (when
                (= family 3)
                (set!
                  (array-ref instructions 0)
                  (instruction
                    (core.OwnershipOperation.Cleanup
                      (linear.obligation 0)
                      (linear.cleanup 1))
                    2
                    0)))
              (set!
                (array-ref blocks 2)
                (core.OwnershipBlock
                  instructions
                  (core.OwnershipTerminator.Goto (linear.block 3))
                  (source
                    2
                    (if (= family 3)
                      1
                      0))))))))
      (set!
        (array-ref blocks 3)
        (core.OwnershipBlock
          (__tl_make-array core.OwnershipInstruction 0)
          (core.OwnershipTerminator.Return
            (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0)))
          (source 3 0)))
      (core.OwnershipBody
        (linear.id)
        types
        locals
        places
        (__tl_make-array core.OwnershipLoan 0)
        (linear.cleanups)
        obligations
        blocks
        (linear.block 0)))))

(define (path [family : i64] [choice : i64]) : Path
  (let
    [operations : i64
      (if (< family 3)
        (*
          choice
          (if (= family 1)
            1
            2))
        (if (or (= family 3) (= choice 0))
          1
          0))]
    [events : (__tl_dyn-array model.Event)
      (__tl_make-array model.Event (+ operations 2))]
    [points : (__tl_dyn-array Point) (__tl_make-array Point (+ operations 2))]
    [index : i64 0]
    (begin
      (set! (array-ref events 0) (model.Event.Initialize model.Owner.Outer))
      (set! (array-ref points 0) (Point 0 0))
      (if (< family 3)
        (while (< index choice)
          (let
            [offset : i64
              (+
                1
                (*
                  index
                  (if (= family 1)
                    1
                    2)))]
            (begin
              (set!
                (array-ref events offset)
                (if (= family 2)
                  (model.Event.Initialize model.Owner.Inner)
                  (model.Event.Cleanup model.Owner.Outer)))
              (set! (array-ref points offset) (Point 2 0))
              (unless
                (= family 1)
                (begin
                  (set!
                    (array-ref events (+ offset 1))
                    (if (= family 2)
                      (model.Event.Leave model.Owner.Inner)
                      (model.Event.Reinitialize model.Owner.Outer)))
                  (set! (array-ref points (+ offset 1)) (Point 2 1))))
              (set! index (+ index 1)))))
        (when
          (> operations 0)
          (begin
            (set! (array-ref events 1) (model.Event.Cleanup model.Owner.Outer))
            (set! (array-ref points 1) (Point (+ choice 1) 0)))))
      (set! (array-ref events (+ operations 1)) model.Event.Exit)
      (set! (array-ref points (+ operations 1)) (Point 3 0))
      (Path events points))))

;; Reuse the concrete interpreter for successful prefixes of rejected traces.
;; No production result decides token effects, field order or owner activation.
(define (prefix-outcome
  [policy : (& policy (Array model.Mode 2))]
  [family : i64]
  [choice : i64]
  [count : i64]) : model.Outcome
  (let
    [input : Path (path family choice)]
    (begin
      ;; Execute stops at Abort; later original events are unreachable.
      (set! (array-ref input.events count) model.Event.Abort)
      (model.execute policy (& input.events)))))

(define (same-point? [left : (& left Point)] [block : i64] [instruction : i64]) : bool
  (and (= left.block block) (= left.instruction instruction)))

(define (actions-match?
  [path : (& path Path)]
  [count : i64]
  [actual : (& actual (__tl_dyn-array core.OwnershipCleanupAction))]
  [expected : (& expected model.Report)]
  [covered : (&mut covered (__tl_dyn-array bool))]) : bool
  (let
    [event : i64 0]
    [next : i64 0]
    [identity : core.OwnershipBodyId (linear.id)]
    (begin
      (unless
        (and
          (= expected.count (array-length expected.actions))
          (= expected.count (array-length expected.log))
          (= (array-length covered) (array-length actual)))
        (return false))
      (while (< event count)
        (let
          [point : (& path Point) (& (array-ref path.points event))]
          [index : i64 0]
          (begin
            (while (< index (array-length actual))
              (let
                [got : (& actual core.OwnershipCleanupAction)
                  (& (array-ref actual index))]
                (begin
                  (when
                    (same-point? point got.block got.instruction)
                    (begin
                      (when (>= next expected.count) (return false))
                      (let
                        [want : (& expected model.CleanupAction)
                          (& (array-ref expected.actions next))]
                        [owner : i64
                          (match (& want.owner)
                            [(model.Owner.Outer) 0]
                            [(model.Owner.Inner) 1])]
                        [field : i64
                          (match (& want.field)
                            [(model.Field.Left) 0]
                            [(model.Field.Right) 1])]
                        (unless
                          (and
                            (= want.event event)
                            (= want.token (array-ref expected.log next))
                            (core.ownership-body-id-equal?
                              got.place.body
                              identity)
                            (= got.place.index (+ (* owner 3) (+ field 1)))
                            (core.ownership-body-id-equal?
                              got.cleanup.body
                              identity)
                            (= got.cleanup.index 0))
                          (return false)))
                      (set! (array-ref covered index) true)
                      (set! next (+ next 1))))
                  (set! index (+ index 1)))))
            (set! event (+ event 1)))))
      (= next expected.count))))

(define (failure-point?
  [actual : (& actual core.OwnershipResult)]
  [point : (& point Point)]) : bool
  (match actual
    [(core.OwnershipResult.Ok) false]
    [(core.OwnershipResult.Err error)
      (and
        (match error.kind
          [(core.OwnershipFailureKind.Uninitialized) true]
          [(core.OwnershipFailureKind.Cleanup) true]
          [_ false])
        (same-point? point error.block error.instruction)
        (string.eq error.source.path "cleanup-cfg-case.tl")
        (= error.source.line (+ 1 (+ (* point.block 16) point.instruction)))
        (= error.source.column 1))]))

(define (graph? [family : i64]) : bool
  (let
    [body : core.OwnershipBody (body family)]
    [actual : core.OwnershipCleanupInspection
      (core.ownership-cleanup-inspect (& body) (core.ownership-default-limits))]
    [ordinary : core.OwnershipResult
      (core.ownership-check (& body) (core.ownership-default-limits))]
    [covered : (__tl_dyn-array bool)
      (__tl_make-array bool (array-length actual.actions))]
    [policy : (Array model.Mode 2) (modes family)]
    [all-valid? : bool true]
    [failure-seen? : bool false]
    [choice : i64 0]
    [index : i64 0]
    (begin
      (unless
        (and
          actual.complete?
          (observation-schema? (& body) (& actual))
          (linear.results-match? (& actual.result) (& ordinary)))
        (return false))
      (while (< index (array-length covered))
        (begin
          (set! (array-ref covered index) false)
          (set! index (+ index 1))))
      (while (<
        choice
        (if (< family 3)
          4
          2))
        (let
          [path : Path (path family choice)]
          [expected : model.Outcome (model.execute (& policy) (& path.events))]
          (begin
            (unless
              (path-schema? (& body) (& path) family choice)
              (return false))
            (match expected
              [(model.Outcome.Accepted report)
                (unless
                  (actions-match?
                    (& path)
                    (array-length path.events)
                    (& actual.actions)
                    (& report)
                    (&mut covered))
                  (return false))]
              [(model.Outcome.Rejected event)
                (begin
                  (set! all-valid? false)
                  (when
                    (or (< event 0) (>= event (array-length path.points)))
                    (return false))
                  ;; Every failed concrete path must be represented at its
                  ;; own original point, even if another path failed first.
                  (let
                    [point : (& path Point) (& (array-ref path.points event))]
                    (unless
                      (!=
                        (bit-and
                          (array-ref
                            actual.failure-kinds
                            (+
                              (array-ref actual.offsets point.block)
                              point.instruction))
                          5)
                        0)
                      (return false)))
                  (when
                    (failure-point?
                      (& actual.result)
                      (& (array-ref path.points event)))
                    (set! failure-seen? true))
                  (match (prefix-outcome (& policy) family choice event)
                    [(model.Outcome.Aborted report)
                      (unless
                        (actions-match?
                          (& path)
                          event
                          (& actual.actions)
                          (& report)
                          (&mut covered))
                        (return false))]
                    [_ (return false)]))]
              [_ (return false)])
            (set! choice (+ choice 1)))))
      (set! index 0)
      (while (< index (array-length covered))
        (begin
          (unless (array-ref covered index) (return false))
          (set! index (+ index 1))))
      (if all-valid?
        (begin
          (set! index 0)
          (while (< index (array-length actual.failure-kinds))
            (begin
              (unless
                (= (array-ref actual.failure-kinds index) 0)
                (return false))
              (set! index (+ index 1))))
          (match actual.result
            [(core.OwnershipResult.Ok) true]
            [_ false]))
        failure-seen?))))

(define (main) : i64
  (let
    [family : i64 0]
    (begin
      (while (< family 5)
        (begin
          (unless
            (graph? family)
            (begin
              (io.println
                "ownership-cleanup-cfg-crosscheck mismatch: graph={}"
                family)
              (return 1)))
          (set! family (+ family 1))))
      (io.println
        "ownership-cleanup-cfg-crosscheck-v1: graphs=5 paths=16 passed")
      0)))

;; Independent input correspondence: walk actual CFG edges using the selected
;; concrete branch choices and consume every resource operation exactly once.
;; Only the explicitly declared ordinary Boolean evaluation may be skipped.
(define (owner-operation?
  [body : (& body core.OwnershipBody)]
  [id : (& id core.OwnershipObligationId)]
  [owner : (& owner model.Owner)]) : bool
  (and
    (>= id.index 0)
    (< id.index (array-length body.obligations))
    (core.ownership-body-id-equal? id.body body.id)
    (=
      (array-ref body.obligations id.index).place.index
      (*
        3
        (match owner
          [(model.Owner.Outer) 0]
          [(model.Owner.Inner) 1])))))

(define (event-operation?
  [body : (& body core.OwnershipBody)]
  [event : (& event model.Event)]
  [operation : (& operation core.OwnershipOperation)]) : bool
  (match event
    [(model.Event.Initialize owner)
      (match operation
        [(core.OwnershipOperation.BindFresh id)
          (owner-operation? body id owner)]
        [_ false])]
    [(model.Event.Cleanup owner)
      (match operation
        [(core.OwnershipOperation.Cleanup id contract)
          (and
            (owner-operation? body id owner)
            (core.ownership-body-id-equal? contract.body body.id)
            (= contract.index 1))]
        [_ false])]
    [(model.Event.Reinitialize owner)
      (match operation
        [(core.OwnershipOperation.Initialize place)
          (and
            (core.ownership-body-id-equal? place.body body.id)
            (=
              place.index
              (*
                3
                (match owner
                  [(model.Owner.Outer) 0]
                  [(model.Owner.Inner) 1]))))]
        [_ false])]
    [(model.Event.Leave owner)
      (match operation
        [(core.OwnershipOperation.Leave id) (owner-operation? body id owner)]
        [_ false])]
    [_ false]))

(define (path-schema?
  [body : (& body core.OwnershipBody)]
  [path : (& path Path)]
  [family : i64]
  [choice : i64]) : bool
  (let
    [block : i64 body.entry.index]
    [event : i64 0]
    [branches : i64 0]
    [steps : i64 0]
    (begin
      (unless
        (= (array-length path.events) (array-length path.points))
        (return false))
      (while (< steps 64)
        (begin
          (when
            (or (< block 0) (>= block (array-length body.blocks)))
            (return false))
          (let
            [node : (& body core.OwnershipBlock)
              (& (array-ref body.blocks block))]
            [index : i64 0]
            (begin
              (while (< index (array-length node.instructions))
                (let
                  [operation : (& body core.OwnershipOperation)
                    (& (array-ref node.instructions index).operation)]
                  [ordinary? : bool
                    (and
                      (< family 3)
                      (= block 1)
                      (= index 0)
                      (match operation
                        [(core.OwnershipOperation.Assign place)
                          (and
                            (= place.index 6)
                            (core.ownership-body-id-equal? place.body body.id))]
                        [_ false]))]
                  (begin
                    (unless
                      ordinary?
                      (begin
                        (when
                          (>= event (array-length path.events))
                          (return false))
                        (unless
                          (and
                            (same-point?
                              (& (array-ref path.points event))
                              block
                              index)
                            (event-operation?
                              body
                              (& (array-ref path.events event))
                              operation))
                          (return false))
                        (set! event (+ event 1))))
                    (set! index (+ index 1)))))
              (match (& node.terminator)
                [(core.OwnershipTerminator.Goto target)
                  (set! block target.index)]
                [(core.OwnershipTerminator.Branch condition yes no)
                  (begin
                    (unless
                      (and
                        (= condition.index 6)
                        (core.ownership-body-id-equal? condition.body body.id)
                        (=
                          block
                          (if (< family 3)
                            1
                            0)))
                      (return false))
                    (set!
                      block
                      (if (if (< family 3)
                        (< branches choice)
                        (= choice 0))
                        yes.index
                        no.index))
                    (set! branches (+ branches 1)))]
                [(core.OwnershipTerminator.Return operands)
                  (return
                    (and
                      (= (array-length operands.items) 0)
                      (= (+ event 1) (array-length path.events))
                      (=
                        branches
                        (if (< family 3)
                          (+ choice 1)
                          1))
                      (same-point?
                        (& (array-ref path.points event))
                        block
                        index)
                      (match (& (array-ref path.events event))
                        [(model.Event.Exit) true]
                        [_ false])))]
                [_ (return false)])))
          (set! steps (+ steps 1))))
      false)))

(define (observation-schema?
  [body : (& body core.OwnershipBody)]
  [actual : (& actual core.OwnershipCleanupInspection)]) : bool
  (let
    [block : i64 0]
    [point : i64 0]
    (begin
      (unless
        (= (array-length actual.offsets) (+ (array-length body.blocks) 1))
        (return false))
      (while (< block (array-length body.blocks))
        (begin
          (unless (= (array-ref actual.offsets block) point) (return false))
          (set!
            point
            (+
              point
              (array-length (array-ref body.blocks block).instructions)
              1))
          (set! block (+ block 1))))
      (unless
        (and
          (= (array-ref actual.offsets block) point)
          (= (array-length actual.failure-kinds) point))
        (return false))
      (set! point 0)
      (while (< point (array-length actual.failure-kinds))
        (let
          [kinds : i64 (array-ref actual.failure-kinds point)]
          (begin
            ;; No loan operation exists in these graphs. Unknown or Loan-only
            ;; bits cannot stand in for a failed initialization/cleanup check.
            (when
              (or (< kinds 0) (> kinds 7) (!= (bit-and kinds 2) 0))
              (return false))
            (set! point (+ point 1)))))
      true)))