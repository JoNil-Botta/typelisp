;; Production comparisons are deliberately outside the independent oracle.
(import main as model)
(import compiler_ownership_core as core)
(import stdlib.io)

(define (crosscheck-id) : core.OwnershipBodyId
  (core.OwnershipBodyId (cast 8449 : u64) (cast 1 : u64) (cast 1 : u64)))

(define (crosscheck-place [index : i64]) : core.OwnershipPlaceId
  (core.OwnershipPlaceId (crosscheck-id) index))

(define (crosscheck-type [index : i64]) : core.OwnershipTypeId
  (core.OwnershipTypeId (crosscheck-id) index))

(define (crosscheck-block [index : i64]) : core.OwnershipBlockId
  (core.OwnershipBlockId (crosscheck-id) index))

(define (crosscheck-source [line : i64]) : core.OwnershipSource
  (core.OwnershipSource "ownership-model-v1" line 1 "independent finite model"))

(define (crosscheck-instruction [code : i64]) : core.OwnershipInstruction
  (let
    [place : core.OwnershipPlaceId (crosscheck-place (% code 6))]
    (core.OwnershipInstruction
      (match (/ code 6)
        [0 (core.OwnershipOperation.Read place)]
        [1 (core.OwnershipOperation.Consume place)]
        [2 (core.OwnershipOperation.Assign place)]
        [_ (core.OwnershipOperation.Invalidate place)])
      (crosscheck-source (+ code 1)))))

(define (crosscheck-place-node
  [local : i64]
  [type : i64]
  [parent : i64]
  [field : i64]) : core.OwnershipPlace
  (core.OwnershipPlace
    (core.OwnershipLocalId (crosscheck-id) local)
    (crosscheck-type type)
    (if (< parent 0)
      core.OwnershipProjection.Root
      (core.OwnershipProjection.Field (crosscheck-place parent) field))
    (crosscheck-source 1)))

;; The six model places retain their ordering. A seventh, always initialized
;; Boolean parameter supplies control-flow branches without constraining them.
(define (crosscheck-body [blocks : (__tl_dyn-array core.OwnershipBlock)]) : core.OwnershipBody
  (core.OwnershipBody
    (crosscheck-id)
    (__tl_make-array
      (core.OwnershipType core.OwnershipTypeKind.Scalar false)
      (core.OwnershipType core.OwnershipTypeKind.Boolean true)
      (core.OwnershipType
        (core.OwnershipTypeKind.Product
          (core.OwnershipTypeIds
            (__tl_make-array (crosscheck-type 0) (crosscheck-type 0))))
        false)
      (core.OwnershipType
        (core.OwnershipTypeKind.Product
          (core.OwnershipTypeIds
            (__tl_make-array (crosscheck-type 0) (crosscheck-type 2))))
        false))
    (__tl_make-array
      (core.OwnershipLocal (crosscheck-type 3) false (crosscheck-source 1))
      (core.OwnershipLocal (crosscheck-type 0) false (crosscheck-source 1))
      (core.OwnershipLocal (crosscheck-type 1) true (crosscheck-source 1)))
    (__tl_make-array
      (crosscheck-place-node 0 3 -1 0)
      (crosscheck-place-node 0 0 0 0)
      (crosscheck-place-node 0 2 0 1)
      (crosscheck-place-node 0 0 2 0)
      (crosscheck-place-node 0 0 2 1)
      (crosscheck-place-node 1 0 -1 0)
      (crosscheck-place-node 2 1 -1 0))
    (__tl_make-array core.OwnershipLoan 0)
    (__tl_make-array core.OwnershipCleanup 0)
    (__tl_make-array core.OwnershipObligation 0)
    blocks
    (crosscheck-block 0)))

(define (crosscheck-empty-block) : core.OwnershipBlock
  (core.OwnershipBlock
    (__tl_make-array core.OwnershipInstruction 0)
    (core.OwnershipTerminator.Return
      (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0)))
    (crosscheck-source 1)))

;; Representation conversion only: the expected transfer still comes from
;; model-step over independently represented Boolean concrete stores.
(define (crosscheck-leaf-state [facts : model.ModelFacts] [bit : i64]) : i64
  (if (!= (bit-and facts.definite bit) 0)
    2
    (if (!= (bit-and facts.possible bit) 0)
      3
      1)))

(define (crosscheck-state [facts : model.ModelFacts]) : (__tl_dyn-array i64)
  (let
    [head : i64 (crosscheck-leaf-state facts 1)]
    [left : i64 (crosscheck-leaf-state facts 2)]
    [right : i64 (crosscheck-leaf-state facts 4)]
    [shadow : i64 (crosscheck-leaf-state facts 8)]
    (__tl_make-array
      (bit-or head (bit-or left right))
      head
      (bit-or left right)
      left
      right
      shadow
      2)))

(define (crosscheck-transfer-case?
  [body : (& body core.OwnershipBody)]
  [abstract-index : i64]
  [code : i64]
  [destination : i64]) : bool
  (let
    [facts : model.ModelFacts (model.model-facts abstract-index)]
    [state : (__tl_dyn-array i64) (crosscheck-state facts)]
    [instruction : core.OwnershipInstruction
      (if (< destination 0)
        (crosscheck-instruction code)
        (core.OwnershipInstruction
          (core.OwnershipOperation.Move
            (crosscheck-place (% code 6))
            (crosscheck-place destination))
          (crosscheck-source (+ code 1))))]
    [expected-valid : bool true]
    [expected-readable : (__tl_dyn-array bool)
      (__tl_make-array true true true true true true)]
    [concrete : i64 0]
    [ok : bool true]
    (begin
      (while (< concrete 16)
        (let
          [value : model.ModelConcrete (model.model-concrete concrete)]
          (when
            (model.model-contains? facts value)
            (let
              [step : model.ModelConcreteStep
                (model.model-step
                  value
                  (model.model-operation (/ code 6))
                  (model.model-place (% code 6)))]
              [next : model.ModelConcrete
                (if (< destination 0)
                  step.value
                  (model.model-write
                    step.value
                    (model.model-place destination)
                    true))]
              [place : i64 0]
              (begin
                (set! expected-valid (and expected-valid step.valid))
                (while (< place 6)
                  (set!
                    (array-ref expected-readable place)
                    (and
                      (array-ref expected-readable place)
                      (model.model-ready? next (model.model-place place))))
                  (set! place (+ place 1)))))))
        (set! concrete (+ concrete 1)))
      (match (core.ownership-transfer! body (&mut state) (& instruction) 0 0)
        [(core.OwnershipResult.Ok)
          (begin
            (set! ok expected-valid)
            (let
              [place : i64 0]
              (while (and ok (< place 6))
                (set!
                  ok
                  (=
                    (core.ownership-state-readable? (array-ref state place))
                    (array-ref expected-readable place)))
                (set! place (+ place 1)))))]
        [(core.OwnershipResult.Err failure)
          (set!
            ok
            (and
              (not expected-valid)
              (= failure.block 0)
              (= failure.instruction 0)
              (= failure.place (% code 6))
              (= failure.source.line (+ code 1))
              (match failure.kind
                [(core.OwnershipFailureKind.Uninitialized) true]
                [_ false])))])
      (unless
        ok
        (if (< destination 0)
          (io.println
            "ownership-crosscheck transfer mismatch: abstract={} operation={}"
            abstract-index
            code)
          (io.println
            "ownership-crosscheck move mismatch: abstract={} source={} destination={}"
            abstract-index
            (% code 6)
            destination)))
      ok)))

(define (crosscheck-transfers-in-arena?) : bool
  (let
    [body : core.OwnershipBody
      (crosscheck-body (__tl_make-array (crosscheck-empty-block)))]
    [ok : bool true]
    [abstract-index : i64 0]
    [checked : i64 0]
    (begin
      (match (core.ownership-validate (& body) (core.ownership-default-limits))
        [(core.OwnershipResult.Ok) unit]
        [(core.OwnershipResult.Err failure)
          (begin
            (io.println
              "ownership-crosscheck malformed fixture: place={} {}"
              failure.place
              failure.message)
            (set! ok false))])
      ;; Bottom has no reachable transfer. All 81 reachable cubes include all
      ;; sixteen singleton stores and every representable join of them.
      (while (and ok (< abstract-index 81))
        (let
          [code : i64 0]
          [source : i64 0]
          [leaves : (Array i64 4) (array 1 3 4 5)]
          (begin
            (while (and ok (< code 24))
              (set!
                ok
                (crosscheck-transfer-case? (& body) abstract-index code -1))
              (set! checked (+ checked 1))
              (set! code (+ code 1)))
            ;; Source-to-destination Move is separately tested on every ordered
            ;; disjoint scalar leaf pair. Model Move clears the source and
            ;; model Initialize sets the destination, independent of core code.
            (while (and ok (< source 4))
              (let
                [dest : i64 0]
                (while (and ok (< dest 4))
                  (when
                    (!= source dest)
                    (set!
                      ok
                      (crosscheck-transfer-case?
                        (& body)
                        abstract-index
                        (+ 6 (array-ref leaves source))
                        (array-ref leaves dest)))
                    (set! checked (+ checked 1)))
                  (set! dest (+ dest 1))))
              (set! source (+ source 1)))))
        (set! abstract-index (+ abstract-index 1)))
      (and ok (= checked 2916)))))

(define (crosscheck-transfers?) : bool
  (with-arena cases (crosscheck-transfers-in-arena?)))

(define (crosscheck-entry [initial : i64]) : core.OwnershipBlock
  (let
    [instructions : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array core.OwnershipInstruction 0)]
    [value : model.ModelConcrete (model.model-concrete initial)]
    (begin
      (when
        value.head
        (__tl_array-push! instructions (crosscheck-instruction 13)))
      (when
        value.left
        (__tl_array-push! instructions (crosscheck-instruction 15)))
      (when
        value.right
        (__tl_array-push! instructions (crosscheck-instruction 16)))
      (when
        value.shadow
        (__tl_array-push! instructions (crosscheck-instruction 17)))
      (core.OwnershipBlock
        instructions
        (core.OwnershipTerminator.Goto (crosscheck-block 1))
        (crosscheck-source 1)))))

(define (crosscheck-arm [code : i64] [exit : i64] [cleanup : bool]) : core.OwnershipBlock
  (let
    [instructions : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array (crosscheck-instruction code))]
    (begin
      ;; Return keeps implicit uses in the terminator; other scope exits read
      ;; retained operands before their explicit jump. Abort has no cleanup.
      (when
        (and cleanup (< exit 3))
        (__tl_array-push! instructions (crosscheck-instruction 2)))
      (core.OwnershipBlock
        instructions
        (match exit
          [4 core.OwnershipTerminator.Abort]
          [3
            (core.OwnershipTerminator.Return
              (core.OwnershipPlaceIds
                (if cleanup
                  (__tl_make-array (crosscheck-place 2))
                  (__tl_make-array core.OwnershipPlaceId 0))))]
          [2 (core.OwnershipTerminator.Goto (crosscheck-block 5))]
          [_ (core.OwnershipTerminator.Goto (crosscheck-block 1))])
        (crosscheck-source 2)))))

;; A rejection must name an operation that independently has a concrete bad
;; execution. An unrelated error or a correct kind at the wrong source is not
;; a passing negative test.
(define (crosscheck-expected-failure?
  [exact : model.ModelConcreteGraph]
  [left : i64]
  [right : i64]
  [cleanup : bool]
  [failure : (& failure core.OwnershipFailure)]) : bool
  (let
    [state : i64 0]
    [witness : bool false]
    (begin
      (while (and (not witness) (< state 16))
        (let
          [value : model.ModelConcrete (model.model-concrete state)]
          (begin
            (when
              (and
                (= failure.block 5)
                (= failure.instruction 0)
                (= failure.place 0)
                (= failure.source.line 6)
                (model.model-state-member? exact.normal state)
                (not (model.model-ready? value model.ModelPlace.Root)))
              (set! witness true))
            (when
              (and
                (or (= failure.block 3) (= failure.block 4))
                (model.model-state-member? exact.header state))
              (let
                [arm : i64
                  (if (= failure.block 3)
                    left
                    right)]
                [code : i64 (% arm 24)]
                [edge : i64 (/ arm 24)]
                [step : model.ModelConcreteStep
                  (model.model-step
                    value
                    (model.model-operation (/ code 6))
                    (model.model-place (% code 6)))]
                (begin
                  (when
                    (and
                      (= failure.instruction 0)
                      (= failure.place (% code 6))
                      (= failure.source.line (+ code 1))
                      (not step.valid))
                    (set! witness true))
                  (when
                    (and
                      cleanup
                      (< edge 4)
                      step.valid
                      (= failure.instruction 1)
                      (= failure.place 2)
                      (=
                        failure.source.line
                        (if (= edge 3)
                          2
                          3))
                      (not
                        (model.model-ready? step.value model.ModelPlace.Tail)))
                    (set! witness true)))))))
        (set! state (+ state 1)))
      witness)))

(define (crosscheck-graph-in-arena?
  [initial : i64]
  [left : i64]
  [right : i64]
  [cleanup : bool]) : bool
  (let
    [exact : model.ModelConcreteGraph
      (model.model-execute-graph
        (model.model-concrete initial)
        (% left 24)
        (model.model-exit (/ left 24))
        (% right 24)
        (model.model-exit (/ right 24))
        cleanup
        32)]
    [body : core.OwnershipBody
      (crosscheck-body
        (__tl_make-array
          (crosscheck-entry initial)
          (core.OwnershipBlock
            (__tl_make-array core.OwnershipInstruction 0)
            (core.OwnershipTerminator.Branch
              (crosscheck-place 6)
              (crosscheck-block 2)
              (crosscheck-block 5))
            (crosscheck-source 2))
          (core.OwnershipBlock
            (__tl_make-array core.OwnershipInstruction 0)
            (core.OwnershipTerminator.Branch
              (crosscheck-place 6)
              (crosscheck-block 3)
              (crosscheck-block 4))
            (crosscheck-source 3))
          (crosscheck-arm (% left 24) (/ left 24) cleanup)
          (crosscheck-arm (% right 24) (/ right 24) cleanup)
          (core.OwnershipBlock
            (__tl_make-array core.OwnershipInstruction 0)
            (core.OwnershipTerminator.Return
              (core.OwnershipPlaceIds (__tl_make-array (crosscheck-place 0))))
            (crosscheck-source 6))))]
    [expected : bool (and exact.complete (not exact.failed))]
    [state : i64 0]
    [matches : bool false]
    (begin
      ;; The normal exit additionally returns Root. This observes moves
      ;; reaching a diamond join, a break join or the loop's zero-trip edge.
      (while (< state 16)
        (when
          (model.model-state-member? exact.normal state)
          (set!
            expected
            (and
              expected
              (model.model-ready?
                (model.model-concrete state)
                model.ModelPlace.Root))))
        (set! state (+ state 1)))
      (match (core.ownership-check (& body) (core.ownership-default-limits))
        [(core.OwnershipResult.Ok) (set! matches expected)]
        [(core.OwnershipResult.Err failure)
          (set!
            matches
            (and
              exact.complete
              (not expected)
              (crosscheck-expected-failure?
                exact
                left
                right
                cleanup
                (& failure))
              (match failure.kind
                [(core.OwnershipFailureKind.Uninitialized) true]
                [_ false])))])
      (unless
        matches
        (io.println
          "ownership-crosscheck graph mismatch: initial={} left={} right={} cleanup={} expected={}"
          initial
          left
          right
          cleanup
          expected))
      matches)))

(define (crosscheck-graph?
  [initial : i64]
  [left : i64]
  [right : i64]
  [cleanup : bool]) : bool
  (with-arena graph (crosscheck-graph-in-arena? initial left right cleanup)))

(define (crosscheck-graphs?) : bool
  (let
    [left : i64 0]
    [ok : bool true]
    [checked : i64 0]
    (begin
      ;; Full entry lets every operation execute before any first rejection.
      ;; Transfer comparisons above exhaust the remaining input cubes.
      (while (and ok (< left 120))
        (let
          [right : i64 0]
          (while (and ok (< right 120))
            (set!
              ok
              (and
                (crosscheck-graph? 15 left right false)
                (crosscheck-graph? 15 left right true)))
            (set! checked (+ checked 2))
            (set! right (+ right 1))))
        (set! left (+ left 1)))
      (and ok (= checked 28800)))))

(define (main) : i64
  (if (and (crosscheck-transfers?) (crosscheck-graphs?))
    (begin
      (io.println "ownership-crosscheck-v1: transfers=2916 graphs=28800 passed")
      0)
    1))