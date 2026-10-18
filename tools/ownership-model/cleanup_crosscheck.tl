;; Production adapter for the independent concrete cleanup interpreter.
;; Expectations and cleanup order come only from cleanup_model. This module
;; translates events into typed operations and compares their checked results.
;; Scope: two lexical owners with two MoveOnly cleanup fields each, explicit
;; construction, whole/field transfers, reinitialization, cleanup and exits.
(import cleanup_model as model)
(import cleanup_cases as cases)
(import cleanup_rename as rename)
(import compiler_ownership_core as core)
(import stdlib.io)
(import stdlib.string)

(define (id) : core.OwnershipBodyId
  (core.OwnershipBodyId (cast 8449 : u64) (cast 7 : u64) (cast 1 : u64)))

(define (type-id [index : i64]) : core.OwnershipTypeId
  (core.OwnershipTypeId (id) index))

(define (place [index : i64]) : core.OwnershipPlaceId
  (core.OwnershipPlaceId (id) index))

(define (cleanup [index : i64]) : core.OwnershipCleanupId
  (core.OwnershipCleanupId (id) index))

(define (obligation [index : i64]) : core.OwnershipObligationId
  (core.OwnershipObligationId (id) index))

(define (block [index : i64]) : core.OwnershipBlockId
  (core.OwnershipBlockId (id) index))

(define (source [event : i64]) : core.OwnershipSource
  (core.OwnershipSource
    "cleanup-case.tl"
    (+ event 1)
    1
    "concrete cleanup event"))

(define (root [owner : model.Owner]) : core.OwnershipPlaceId
  (place (* 3 (model.owner-index owner))))

(define (field [owner : model.Owner] [member : model.Field]) : core.OwnershipPlaceId
  (place (+ (* 3 (model.owner-index owner)) (+ 1 (model.field-index member)))))

(define (instruction [operation : core.OwnershipOperation] [event : i64]) : core.OwnershipInstruction
  (core.OwnershipInstruction operation (source event)))

;; Two constructor operands parse as type/length because the first also has
;; nominal type syntax. Use an explicitly typed buffer for this two-item list.
(define (types) : (__tl_dyn-array core.OwnershipType)
  (let
    [out
      : (__tl_dyn-array core.OwnershipType)
      ;; lint-allow: prefer-dynamic-array-literal
      (__tl_make-array core.OwnershipType 2)]
    (begin
      (set!
        (array-ref out 0)
        (core.OwnershipType core.OwnershipTypeKind.Scalar false))
      (set!
        (array-ref out 1)
        (core.OwnershipType
          (core.OwnershipTypeKind.Product
            (core.OwnershipTypeIds (__tl_make-array (type-id 0) (type-id 0))))
          false))
      out)))

(define (locals) : (__tl_dyn-array core.OwnershipLocal)
  (__tl_make-array
    (core.OwnershipLocal (type-id 1) false (source 0))
    (core.OwnershipLocal (type-id 1) false (source 0))))

(define (places) : (__tl_dyn-array core.OwnershipPlace)
  (let
    [out : (__tl_dyn-array core.OwnershipPlace)
      (__tl_make-array core.OwnershipPlace 6)]
    [owner : i64 0]
    (begin
      (while (< owner 2)
        (let
          [base : i64 (* owner 3)]
          [local : core.OwnershipLocalId (core.OwnershipLocalId (id) owner)]
          (begin
            (set!
              (array-ref out base)
              (core.OwnershipPlace
                local
                (type-id 1)
                core.OwnershipProjection.Root
                (source 0)))
            (set!
              (array-ref out (+ base 1))
              (core.OwnershipPlace
                local
                (type-id 0)
                (core.OwnershipProjection.Field (place base) 0)
                (source 0)))
            (set!
              (array-ref out (+ base 2))
              (core.OwnershipPlace
                local
                (type-id 0)
                (core.OwnershipProjection.Field (place base) 1)
                (source 0)))
            (set! owner (+ owner 1)))))
      out)))

(define (cleanups) : (__tl_dyn-array core.OwnershipCleanup)
  (__tl_make-array
    (core.OwnershipCleanup
      (type-id 0)
      true
      core.OwnershipCleanupKind.Intrinsic
      (source 0))
    (core.OwnershipCleanup
      (type-id 1)
      true
      (core.OwnershipCleanupKind.Product
        (core.OwnershipCleanupFields
          (__tl_make-array
            (core.OwnershipCleanupField 0 (cleanup 0))
            (core.OwnershipCleanupField 1 (cleanup 0)))))
      (source 0))))

;; This state tracks only syntactic scope events, never resource validity.
;; Repeated activation of a still-active owner uses the same obligation, so
;; the production checker must diagnose it rather than the adapter filtering it.
(defstruct Translation
  (instructions (__tl_dyn-array core.OwnershipInstruction))
  (obligations (__tl_dyn-array core.OwnershipObligation))
  (current (Array i64 2))
  (stack (__tl_dyn-array i64))
  (depth i64)
  (terminator core.OwnershipTerminator)
  (terminal-event i64)
  (finished? bool))

(define (activate!
  [state : (&mut state Translation)]
  [modes : (& modes (Array model.Mode 2))]
  [owner : model.Owner]
  [event : i64]) : core.OwnershipObligationId
  (let
    [slot : i64 (model.owner-index owner)]
    [prior : i64 (array-ref state.current slot)]
    (if (>= prior 0)
      (obligation prior)
      (let
        [index : i64 (array-length state.obligations)]
        [parent : core.OwnershipObligationParent
          (if (= state.depth 0)
            core.OwnershipObligationParent.Root
            (core.OwnershipObligationParent.Parent
              (obligation (array-ref state.stack (- state.depth 1)))))]
        (begin
          (__tl_array-push!
            state.obligations
            (core.OwnershipObligation
              parent
              (root owner)
              (match (array-ref modes slot)
                [(model.Mode.Automatic)
                  core.OwnershipObligationMode.AutomaticRequired]
                [(model.Mode.Discharge) core.OwnershipObligationMode.Discharge])
              (cleanup 1)
              (__tl_make-array core.OwnershipCleanupUse 0)
              (source event)))
          (set! (array-ref state.current slot) index)
          (set! (array-ref state.stack state.depth) index)
          (set! state.depth (+ state.depth 1))
          (obligation index))))))

(define (current!
  [state : (&mut state Translation)]
  [modes : (& modes (Array model.Mode 2))]
  [owner : model.Owner]
  [event : i64]) : core.OwnershipObligationId
  ;; Operations on an unbound owner still require valid metadata. Supply an
  ;; inactive root obligation without inserting a binding instruction or
  ;; changing the syntactic active stack. The checker decides validity.
  (let
    [slot : i64 (model.owner-index owner)]
    [prior : i64 (array-ref state.current slot)]
    (if (>= prior 0)
      (obligation prior)
      (let
        [index : i64 (array-length state.obligations)]
        (begin
          (__tl_array-push!
            state.obligations
            (core.OwnershipObligation
              core.OwnershipObligationParent.Root
              (root owner)
              (match (array-ref modes slot)
                [(model.Mode.Automatic)
                  core.OwnershipObligationMode.AutomaticRequired]
                [(model.Mode.Discharge) core.OwnershipObligationMode.Discharge])
              (cleanup 1)
              (__tl_make-array core.OwnershipCleanupUse 0)
              (source event)))
          (obligation index))))))

(define (emit!
  [state : (&mut state Translation)]
  [operation : core.OwnershipOperation]
  [event : i64]) : unit
  (__tl_array-push! state.instructions (instruction operation event)))

(define (declare-unused!
  [state : (&mut state Translation)]
  [modes : (& modes (Array model.Mode 2))]) : unit
  ;; Both model slots have a resource contract even when no activation event
  ;; reaches them. Metadata declares that responsibility; it does not activate
  ;; a scope or initialize storage. Omitting it would turn a bad field write
  ;; into an unrelated malformed-body test.
  (let
    [slot : i64 0]
    (while (< slot 2)
      (let
        [index : i64 0]
        [declared? : bool false]
        (begin
          (while (< index (array-length state.obligations))
            (begin
              (when
                (= (array-ref state.obligations index).place.index (* slot 3))
                (set! declared? true))
              (set! index (+ index 1))))
          (unless
            declared?
            (let
              [owner : model.Owner
                (if (= slot 0)
                  model.Owner.Outer
                  model.Owner.Inner)]
              [_unused : core.OwnershipObligationId
                (current! state modes owner 0)]
              unit))
          (set! slot (+ slot 1)))))))

(define (translate-event!
  [state : (&mut state Translation)]
  [modes : (& modes (Array model.Mode 2))]
  [value : model.Event]
  [event : i64]) : unit
  (match value
    [(model.Event.Initialize owner)
      (let
        [owner-id : core.OwnershipObligationId
          (activate! state modes owner event)]
        (emit! state (core.OwnershipOperation.BindFresh owner-id) event))]
    [(model.Event.BeginConstruction owner)
      (let
        [owner-id : core.OwnershipObligationId
          (activate! state modes owner event)]
        (emit! state (core.OwnershipOperation.BeginConstruction owner-id) event))]
    [(model.Event.BindComplete owner)
      (let
        [owner-id : core.OwnershipObligationId
          (current! state modes owner event)]
        (emit! state (core.OwnershipOperation.BindComplete owner-id) event))]
    [(model.Event.Reinitialize owner)
      (emit! state (core.OwnershipOperation.Initialize (root owner)) event)]
    [(model.Event.InitializeField owner member)
      (emit!
        state
        (core.OwnershipOperation.Initialize (field owner member))
        event)]
    [(model.Event.Read owner)
      (emit! state (core.OwnershipOperation.Read (root owner)) event)]
    [(model.Event.Move from into)
      (let
        [owner-id : core.OwnershipObligationId
          (activate! state modes into event)]
        (emit!
          state
          (core.OwnershipOperation.BindMove (root from) owner-id)
          event))]
    [(model.Event.MoveField from member into destination)
      (emit!
        state
        (core.OwnershipOperation.Move
          (field from member)
          (field into destination))
        event)]
    [(model.Event.Cleanup owner)
      (let
        [owner-id : core.OwnershipObligationId
          (current! state modes owner event)]
        (emit!
          state
          (core.OwnershipOperation.Cleanup owner-id (cleanup 1))
          event))]
    [(model.Event.CleanupField owner member)
      (emit!
        state
        (core.OwnershipOperation.CleanupPlace (field owner member) (cleanup 0))
        event)]
    [(model.Event.Leave owner)
      (let
        [owner-id : core.OwnershipObligationId
          (current! state modes owner event)]
        (begin
          (emit! state (core.OwnershipOperation.Leave owner-id) event)
          ;; Only the syntactically matching top frame is removed. An invalid
          ;; non-LIFO Leave remains represented and must fail in production.
          (when
            (and
              (> state.depth 0)
              (= (array-ref state.stack (- state.depth 1)) owner-id.index))
            (begin
              (set! state.depth (- state.depth 1))
              (set! (array-ref state.current (model.owner-index owner)) -1)))))]
    [(model.Event.Return owner)
      (begin
        (set!
          state.terminator
          (core.OwnershipTerminator.ReturnOwned
            (core.OwnershipPlaceIds (__tl_make-array (root owner)))))
        (set! state.terminal-event event)
        (set! state.finished? true))]
    [(model.Event.Exit)
      (begin
        (set!
          state.terminator
          (core.OwnershipTerminator.Return
            (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0))))
        (set! state.terminal-event event)
        (set! state.finished? true))]
    [(model.Event.Abort)
      (begin
        (set! state.terminator core.OwnershipTerminator.Abort)
        (set! state.terminal-event event)
        (set! state.finished? true))]
    [(model.Event.AbortCleanup owner)
      (begin
        (emit! state (core.OwnershipOperation.Read (root owner)) event)
        (emit!
          state
          (core.OwnershipOperation.CleanupPlace
            (field owner model.Field.Right)
            (cleanup 0))
          event)
        (set! state.terminator core.OwnershipTerminator.Abort)
        (set! state.terminal-event event)
        (set! state.finished? true))]))

(define (translate
  [modes : (& modes (Array model.Mode 2))]
  [trace : (& trace (__tl_dyn-array model.Event))]) : core.OwnershipBody
  (let
    [state : Translation
      (Translation
        (__tl_make-array core.OwnershipInstruction 0)
        (__tl_make-array core.OwnershipObligation 0)
        (array -1 -1)
        (__tl_make-array i64 128)
        0
        core.OwnershipTerminator.Abort
        0
        false)]
    [index : i64 0]
    (begin
      (when
        (or (= (array-length trace) 0) (> (array-length trace) 128))
        (io.panic "cleanup adapter: invalid trace bound"))
      (while (and (< index (array-length trace)) (not state.finished?))
        (begin
          (translate-event! (&mut state) modes (array-ref trace index) index)
          (set! index (+ index 1))))
      (unless
        state.finished?
        (io.panic "cleanup adapter: missing terminal event"))
      (declare-unused! (&mut state) modes)
      (core.OwnershipBody
        (id)
        (types)
        (locals)
        (places)
        (__tl_make-array core.OwnershipLoan 0)
        (cleanups)
        state.obligations
        (__tl_make-array
          (core.OwnershipBlock
            state.instructions
            state.terminator
            (source state.terminal-event)))
        (block 0)))))

(define (point-event
  [body : (& body core.OwnershipBody)]
  [block-index : i64]
  [instruction-index : i64]) : i64
  (if (or
    (!= block-index 0)
    (< instruction-index 0)
    (> instruction-index (array-length (array-ref body.blocks 0).instructions)))
    -1
    (if (=
      instruction-index
      (array-length (array-ref body.blocks 0).instructions))
      (- (array-ref body.blocks 0).source.line 1)
      (-
        (array-ref (array-ref body.blocks 0).instructions instruction-index).source.line
        1))))

(define (actions-match?
  [body : (& body core.OwnershipBody)]
  [actual : (& actual (__tl_dyn-array core.OwnershipCleanupAction))]
  [expected : (& expected model.Report)]) : bool
  (if (or
    (!= (array-length actual) expected.count)
    (!= (array-length expected.actions) expected.count)
    (!= (array-length expected.log) expected.count))
    false
    (let
      [index : i64 0]
      (begin
        (while (< index expected.count)
          (let
            [got : (& actual core.OwnershipCleanupAction)
              (& (array-ref actual index))]
            [want : (& expected model.CleanupAction)
              (& (array-ref expected.actions index))]
            [owner-index : i64
              (match (& want.owner)
                [(model.Owner.Outer) 0]
                [(model.Owner.Inner) 1])]
            [field-index : i64
              (match (& want.field)
                [(model.Field.Left) 0]
                [(model.Field.Right) 1])]
            (begin
              (unless
                (and
                  (= (point-event body got.block got.instruction) want.event)
                  (core.ownership-body-id-equal? got.place.body body.id)
                  (= got.place.index (+ (* owner-index 3) (+ field-index 1)))
                  (core.ownership-body-id-equal? got.cleanup.body body.id)
                  (= got.cleanup.index 0)
                  (= want.token (array-ref expected.log index)))
                (return false))
              (set! index (+ index 1)))))
        true))))

(define (rejection-match?
  [body : (& body core.OwnershipBody)]
  [error : (& error core.OwnershipFailure)]
  [event : i64]) : bool
  (and
    (match error.kind
      [(core.OwnershipFailureKind.Uninitialized) true]
      [(core.OwnershipFailureKind.Cleanup) true]
      [_ false])
    (= error.block 0)
    (>= error.instruction 0)
    (<= error.instruction (array-length (array-ref body.blocks 0).instructions))
    (string.eq error.source.path "cleanup-case.tl")
    (= error.source.line (+ event 1))
    (= error.source.column 1)
    (= (point-event body error.block error.instruction) event)))

(define (failure-code [kind : (& kind core.OwnershipFailureKind)]) : i64
  (match kind
    [(core.OwnershipFailureKind.Structural) 0]
    [(core.OwnershipFailureKind.Unsupported) 1]
    [(core.OwnershipFailureKind.Uninitialized) 2]
    [(core.OwnershipFailureKind.Loan) 3]
    [(core.OwnershipFailureKind.Cleanup) 4]
    [(core.OwnershipFailureKind.Resource) 5]))

(define (results-match?
  [first : (& first core.OwnershipResult)]
  [second : (& second core.OwnershipResult)]) : bool
  (match first
    [(core.OwnershipResult.Ok)
      (match second
        [(core.OwnershipResult.Ok) true]
        [(core.OwnershipResult.Err _) false])]
    [(core.OwnershipResult.Err left)
      (match second
        [(core.OwnershipResult.Ok) false]
        [(core.OwnershipResult.Err right)
          (and
            (= (failure-code (& left.kind)) (failure-code (& right.kind)))
            (= left.block right.block)
            (= left.instruction right.instruction)
            (= left.place right.place)
            (= left.loan right.loan)
            (= left.conflicting-loan right.conflicting-loan)
            (string.eq left.source.path right.source.path)
            (= left.source.line right.source.line)
            (= left.source.column right.source.column)
            (string.eq left.source.expansion right.source.expansion)
            (string.eq left.message right.message))])]))

(define (case-mode?
  [modes : (& modes (Array model.Mode 2))]
  [trace : (& trace (__tl_dyn-array model.Event))]
  [mode : i64]) : bool
  (let
    [expected : model.Outcome (model.execute modes trace)]
    [body : core.OwnershipBody (translate modes trace)]
    [_renamed : unit
      (unless (rename.apply-mode! (&mut body) mode) (return false))]
    [actual : core.OwnershipCleanupInspection
      (core.ownership-cleanup-inspect (& body) (core.ownership-default-limits))]
    [ordinary : core.OwnershipResult
      (core.ownership-check (& body) (core.ownership-default-limits))]
    (and
      (results-match? (& ordinary) (& actual.result))
      (match expected
        [(model.Outcome.Accepted report)
          (and
            actual.complete?
            (match actual.result
              [(core.OwnershipResult.Ok) true]
              [(core.OwnershipResult.Err _) false])
            (actions-match? (& body) (& actual.actions) (& report)))]
        [(model.Outcome.Aborted report)
          (and
            actual.complete?
            (match actual.result
              [(core.OwnershipResult.Ok) true]
              [(core.OwnershipResult.Err _) false])
            (actions-match? (& body) (& actual.actions) (& report)))]
        [(model.Outcome.Rejected event)
          (match actual.result
            [(core.OwnershipResult.Ok) false]
            [(core.OwnershipResult.Err error)
              (rejection-match? (& body) (& error) event)])]
        [(model.Outcome.InvalidInput) false]))))

(define (case?
  [modes : (& modes (Array model.Mode 2))]
  [trace : (& trace (__tl_dyn-array model.Event))]) : bool
  (let
    [mode : i64 0]
    (begin
      (while (< mode 3)
        (begin
          (unless
            (case-mode? modes trace mode)
            (begin
              (when
                (> mode 0)
                (io.println
                  "ownership-cleanup-crosscheck renaming mismatch: mode={}"
                  mode))
              (return false)))
          (set! mode (+ mode 1))))
      true)))

(define (direct-cases?) : bool
  (let
    [manual : i64 0]
    (begin
      (while (< manual 4)
        (let
          [initial : i64 0]
          (begin
            (while (< initial 4)
              (let
                [operation : i64 0]
                (begin
                  (while (< operation 12)
                    (let
                      [input : cases.Input
                        (cases.direct-input manual initial operation)]
                      (begin
                        (unless
                          (case? (& input.modes) (& input.trace))
                          (begin
                            (io.println
                              "ownership-cleanup-crosscheck direct mismatch: modes={} initial={} operation={}"
                              manual
                              initial
                              operation)
                            (return false)))
                        (set! operation (+ operation 1)))))
                  (set! initial (+ initial 1)))))
            (set! manual (+ manual 1)))))
      true)))

(define (controls?) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (cases.control-count))
        (let
          [input : cases.Input (cases.control-input index)]
          (begin
            (unless
              (case? (& input.modes) (& input.trace))
              (begin
                (io.println
                  "ownership-cleanup-crosscheck control mismatch: case={}"
                  index)
                (return false)))
            (set! index (+ index 1)))))
      true)))

(define (main) : i64
  (if (and (direct-cases?) (controls?))
    (begin
      (io.println
        "ownership-cleanup-crosscheck-v1: direct=576 controls=90 passed")
      0)
    1))