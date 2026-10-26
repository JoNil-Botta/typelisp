;; An executable, finite ownership semantics independent of the compiler.
;; No compiler module or production transfer implementation is imported.
;; Bounds and the relationship to SPEC are documented in README.md. Refs #8449.
(import stdlib.io)
(import stdlib.test)

(defenum ModelPlace
  (Root)
  (Head)
  (Tail)
  (Left)
  (Right)
  (Shadow))

(defenum ModelOperation
  (Read)
  (Move)
  (Initialize)
  (Invalidate))

(defenum ModelExit
  (Fallthrough)
  (Continue)
  (Break)
  (Return)
  (Abort))

;; Concrete storage is a product of booleans, not the abstract bitset.
;; root = (head, tail = (left, right)); shadow is another binding.
(defstruct ModelConcrete
  (head bool)
  (left bool)
  (right bool)
  (shadow bool))

(defstruct ModelConcreteStep
  (value ModelConcrete)
  (valid bool))

(defstruct ModelFacts
  (reachable bool)
  (definite i64)
  (possible i64))

(defstruct ModelTransfer
  (facts ModelFacts)
  (failed bool))

(define (model-place [index : i64]) : ModelPlace
  (match index
    [0 (ModelPlace.Root)]
    [1 (ModelPlace.Head)]
    [2 (ModelPlace.Tail)]
    [3 (ModelPlace.Left)]
    [4 (ModelPlace.Right)]
    [5 (ModelPlace.Shadow)]
    [_ (io.panic "ownership model: place index outside bounds")]))

(define (model-operation [index : i64]) : ModelOperation
  (match index
    [0 (ModelOperation.Read)]
    [1 (ModelOperation.Move)]
    [2 (ModelOperation.Initialize)]
    [3 (ModelOperation.Invalidate)]
    [_ (io.panic "ownership model: operation index outside bounds")]))

(define (model-exit [index : i64]) : ModelExit
  (match index
    [0 (ModelExit.Fallthrough)]
    [1 (ModelExit.Continue)]
    [2 (ModelExit.Break)]
    [3 (ModelExit.Return)]
    [4 (ModelExit.Abort)]
    [_ (io.panic "ownership model: exit index outside bounds")]))

;; Independently written concrete rules use the projection tree, not masks.
(define (model-ready? [value : ModelConcrete] [place : ModelPlace]) : bool
  (match place
    [(ModelPlace.Root) (and value.head value.left value.right)]
    [(ModelPlace.Head) value.head]
    [(ModelPlace.Tail) (and value.left value.right)]
    [(ModelPlace.Left) value.left]
    [(ModelPlace.Right) value.right]
    [(ModelPlace.Shadow) value.shadow]))

(define (model-write
  [value : ModelConcrete]
  [place : ModelPlace]
  [initialized : bool]) : ModelConcrete
  (match place
    [(ModelPlace.Root)
      (ModelConcrete initialized initialized initialized value.shadow)]
    [(ModelPlace.Head)
      (ModelConcrete initialized value.left value.right value.shadow)]
    [(ModelPlace.Tail)
      (ModelConcrete value.head initialized initialized value.shadow)]
    [(ModelPlace.Left)
      (ModelConcrete value.head initialized value.right value.shadow)]
    [(ModelPlace.Right)
      (ModelConcrete value.head value.left initialized value.shadow)]
    [(ModelPlace.Shadow)
      (ModelConcrete value.head value.left value.right initialized)]))

(define (model-step
  [value : ModelConcrete]
  [operation : ModelOperation]
  [place : ModelPlace]) : ModelConcreteStep
  (match operation
    [(ModelOperation.Read) (ModelConcreteStep value (model-ready? value place))]
    [(ModelOperation.Move)
      (ModelConcreteStep
        (model-write value place false)
        (model-ready? value place))]
    [(ModelOperation.Initialize)
      (ModelConcreteStep (model-write value place true) true)]
    [(ModelOperation.Invalidate)
      (ModelConcreteStep (model-write value place false) true)]))

(define (model-concrete [index : i64]) : ModelConcrete
  (ModelConcrete
    (= (% index 2) 1)
    (= (% (/ index 2) 2) 1)
    (= (% (/ index 4) 2) 1)
    (= (% (/ index 8) 2) 1)))

(define (model-concrete-id [value : ModelConcrete]) : i64
  (+
    (if value.head
      1
      0)
    (if value.left
      2
      0)
    (if value.right
      4
      0)
    (if value.shadow
      8
      0)))

(define (model-mask [place : ModelPlace]) : i64
  (match place
    [(ModelPlace.Root) 7]
    [(ModelPlace.Head) 1]
    [(ModelPlace.Tail) 6]
    [(ModelPlace.Left) 2]
    [(ModelPlace.Right) 4]
    [(ModelPlace.Shadow) 8]))

(define (model-bottom) : ModelFacts
  (ModelFacts false 0 0))

(define (model-point [value : ModelConcrete]) : ModelFacts
  (let
    [bits : i64 (model-concrete-id value)]
    (ModelFacts true bits bits)))

(define (model-equal? [a : ModelFacts] [b : ModelFacts]) : bool
  (and
    (= a.reachable b.reachable)
    (= a.definite b.definite)
    (= a.possible b.possible)))

;; a <= b means that b represents at least every concrete state of a.
(define (model-leq? [a : ModelFacts] [b : ModelFacts]) : bool
  (or
    (not a.reachable)
    (and
      b.reachable
      (= (bit-and a.definite b.definite) b.definite)
      (= (bit-or a.possible b.possible) b.possible))))

(define (model-join [a : ModelFacts] [b : ModelFacts]) : ModelFacts
  (if (not a.reachable)
    b
    (if (not b.reachable)
      a
      (ModelFacts
        true
        (bit-and a.definite b.definite)
        (bit-or a.possible b.possible)))))

(define (model-contains? [facts : ModelFacts] [value : ModelConcrete]) : bool
  (let
    [bits : i64 (model-concrete-id value)]
    (and
      facts.reachable
      (= (bit-and bits facts.definite) facts.definite)
      (= (bit-or bits facts.possible) facts.possible))))

(define (model-transfer
  [facts : ModelFacts]
  [operation : ModelOperation]
  [place : ModelPlace]) : ModelTransfer
  (if (not facts.reachable)
    (ModelTransfer facts false)
    (let
      [mask : i64 (model-mask place)]
      [clear : i64 (- 15 mask)]
      [ready : bool (= (bit-and facts.definite mask) mask)]
      (match operation
        [(ModelOperation.Read) (ModelTransfer facts (not ready))]
        [(ModelOperation.Move)
          (ModelTransfer
            (ModelFacts
              true
              (bit-and facts.definite clear)
              (bit-and facts.possible clear))
            (not ready))]
        [(ModelOperation.Initialize)
          (ModelTransfer
            (ModelFacts
              true
              (bit-or facts.definite mask)
              (bit-or facts.possible mask))
            false)]
        [(ModelOperation.Invalidate)
          (ModelTransfer
            (ModelFacts
              true
              (bit-and facts.definite clear)
              (bit-and facts.possible clear))
            false)]))))

;; Every cube over four leaves appears exactly once: 3^4 plus bottom.
(define (model-facts [index : i64]) : ModelFacts
  (if (= index 81)
    (model-bottom)
    (let
      [remaining : i64 index]
      [bit : i64 1]
      [definite : i64 0]
      [possible : i64 0]
      (begin
        (while (< bit 16)
          (let
            [digit : i64 (% remaining 3)]
            (begin
              (when (= digit 1) (set! definite (+ definite bit)))
              (when (> digit 0) (set! possible (+ possible bit)))
              (set! bit (* bit 2))
              (set! remaining (/ remaining 3)))))
        (ModelFacts true definite possible)))))

(define (model-require
  [condition : bool]
  [obligation : (& obligation str)]
  [first : i64]
  [second : i64]
  [third : i64]) : bool
  (begin
    (unless
      condition
      (io.println
        "ownership-model counterexample: {} first={} second={} third={}"
        obligation
        first
        second
        third))
    condition))

(define (model-lattice-laws?) : bool
  (let
    [ok : bool true]
    [a : i64 0]
    (begin
      (while (and ok (< a 82))
        (let
          [left : ModelFacts (model-facts a)]
          [b : i64 0]
          (begin
            (set!
              ok
              (model-require
                (and
                  (model-equal? (model-join left left) left)
                  (model-equal? (model-join left (model-bottom)) left))
                "join idempotence/bottom"
                a
                0
                0))
            (while (and ok (< b 82))
              (let
                [right : ModelFacts (model-facts b)]
                [joined : ModelFacts (model-join left right)]
                [c : i64 0]
                (begin
                  (set!
                    ok
                    (model-require
                      (and
                        (model-equal? joined (model-join right left))
                        (model-leq? left joined)
                        (model-leq? right joined))
                      "join commutativity/upper bound"
                      a
                      b
                      0))
                  (while (and ok (< c 82))
                    (let
                      [third : ModelFacts (model-facts c)]
                      (set!
                        ok
                        (model-require
                          (and
                            (model-equal?
                              (model-join joined third)
                              (model-join left (model-join right third)))
                            (or
                              (not
                                (and
                                  (model-leq? left third)
                                  (model-leq? right third)))
                              (model-leq? joined third)))
                          "join associativity/least upper bound"
                          a
                          b
                          c)))
                    (set! c (+ c 1)))))
              (set! b (+ b 1)))))
        (set! a (+ a 1)))
      ok)))

(define (model-transfer-laws?) : bool
  (let
    [ok : bool true]
    [a : i64 0]
    (begin
      (while (and ok (< a 82))
        (let
          [facts : ModelFacts (model-facts a)]
          [code : i64 0]
          (while (and ok (< code 24))
            (let
              [operation : ModelOperation (model-operation (/ code 6))]
              [place : ModelPlace (model-place (% code 6))]
              [abstract : ModelTransfer (model-transfer facts operation place)]
              [concrete : i64 0]
              [bad : bool false]
              [b : i64 0]
              (begin
                (while (and ok (< concrete 16))
                  (let
                    [value : ModelConcrete (model-concrete concrete)]
                    (when
                      (model-contains? facts value)
                      (let
                        [step : ModelConcreteStep
                          (model-step value operation place)]
                        (if step.valid
                          (set!
                            ok
                            (model-require
                              (model-contains? abstract.facts step.value)
                              "transfer over-approximation"
                              a
                              code
                              concrete))
                          (set! bad true)))))
                  (set! concrete (+ concrete 1)))
                (set!
                  ok
                  (and
                    ok
                    (model-require
                      (= abstract.failed bad)
                      "transfer rejection exactness"
                      a
                      code
                      0)))
                (while (and ok (< b 82))
                  (let
                    [larger : ModelFacts (model-facts b)]
                    (when
                      (model-leq? facts larger)
                      (let
                        [next : ModelTransfer
                          (model-transfer larger operation place)]
                        (set!
                          ok
                          (model-require
                            (and
                              (model-leq? abstract.facts next.facts)
                              (or (not abstract.failed) next.failed))
                            "transfer monotonicity"
                            a
                            b
                            code)))))
                  (set! b (+ b 1)))))
            (set! code (+ code 1))))
        (set! a (+ a 1)))
      ok)))

;; The graph has a nondeterministic loop header with a zero-trip exit and two
;; arms. Each arm has one operation and an explicit exit. Fallthrough and
;; continue return to the header; break joins the normal exit; return and abort
;; have separate terminal outcomes. Optional retained cleanup reads Tail on
;; every scope-leaving edge except Abort. No concrete execution bound is used:
;; the concrete interpreter explores its complete finite reachable state set.
(defstruct ModelConcreteGraph
  (header i64)
  (normal i64)
  (returned i64)
  (aborted i64)
  (failed bool)
  (complete bool))

(defstruct ModelAbstractGraph
  (header ModelFacts)
  (normal ModelFacts)
  (returned ModelFacts)
  (aborted ModelFacts)
  (failed bool)
  (complete bool))

(define (model-state-member? [states : i64] [index : i64]) : bool
  (!= (bit-and states (shl 1 index)) 0))

(define (model-execute-graph
  [initial : ModelConcrete]
  [left-code : i64]
  [left-exit : ModelExit]
  [right-code : i64]
  [right-exit : ModelExit]
  [cleanup : bool]
  [budget : i64]) : ModelConcreteGraph
  (let
    [entry : i64 (shl 1 (model-concrete-id initial))]
    [result : ModelConcreteGraph
      (ModelConcreteGraph entry entry 0 0 false false)]
    [visited : i64 0]
    [fuel : i64 0]
    (begin
      (while (and (!= visited result.header) (< fuel budget))
        (let
          [pending : i64 (bit-xor visited result.header)]
          [state : i64 0]
          (begin
            (set! visited result.header)
            (while (< state 16)
              (when
                (model-state-member? pending state)
                (let
                  [arm : i64 0]
                  (while (< arm 2)
                    (let
                      [code : i64
                        (if (= arm 0)
                          left-code
                          right-code)]
                      [edge : ModelExit
                        (if (= arm 0)
                          left-exit
                          right-exit)]
                      [step : ModelConcreteStep
                        (model-step
                          (model-concrete state)
                          (model-operation (/ code 6))
                          (model-place (% code 6)))]
                      (if (not step.valid)
                        (set! result.failed true)
                        (let
                          [target : i64 (shl 1 (model-concrete-id step.value))]
                          [clean : bool
                            (or
                              (not cleanup)
                              (model-ready? step.value (ModelPlace.Tail)))]
                          (match edge
                            [(ModelExit.Abort)
                              (set!
                                result.aborted
                                (bit-or result.aborted target))]
                            [(ModelExit.Return)
                              (if clean
                                (set!
                                  result.returned
                                  (bit-or result.returned target))
                                (set! result.failed true))]
                            [(ModelExit.Break)
                              (if clean
                                (set!
                                  result.normal
                                  (bit-or result.normal target))
                                (set! result.failed true))]
                            [(ModelExit.Continue)
                              (if clean
                                (begin
                                  (set!
                                    result.header
                                    (bit-or result.header target))
                                  (set!
                                    result.normal
                                    (bit-or result.normal target)))
                                (set! result.failed true))]
                            [(ModelExit.Fallthrough)
                              (if clean
                                (begin
                                  (set!
                                    result.header
                                    (bit-or result.header target))
                                  (set!
                                    result.normal
                                    (bit-or result.normal target)))
                                (set! result.failed true))]))))
                    (set! arm (+ arm 1)))))
              (set! state (+ state 1)))))
        (set! fuel (+ fuel 1)))
      (set! result.complete (= visited result.header))
      result)))

(define (model-analyze-graph
  [initial : ModelConcrete]
  [left-code : i64]
  [left-exit : ModelExit]
  [right-code : i64]
  [right-exit : ModelExit]
  [cleanup : bool]
  [budget : i64]) : ModelAbstractGraph
  (let
    [entry : ModelFacts (model-point initial)]
    [result : ModelAbstractGraph
      (ModelAbstractGraph entry entry (model-bottom) (model-bottom) false false)]
    [changed : bool true]
    [fuel : i64 0]
    (begin
      (while (and changed (< fuel budget))
        (let
          [before : ModelFacts
            (ModelFacts
              result.header.reachable
              result.header.definite
              result.header.possible)]
          [arm : i64 0]
          (begin
            (while (< arm 2)
              (let
                [code : i64
                  (if (= arm 0)
                    left-code
                    right-code)]
                [edge : ModelExit
                  (if (= arm 0)
                    left-exit
                    right-exit)]
                [step : ModelTransfer
                  (model-transfer
                    before
                    (model-operation (/ code 6))
                    (model-place (% code 6)))]
                (begin
                  (set! result.failed (or result.failed step.failed))
                  (match edge
                    [(ModelExit.Abort)
                      (set!
                        result.aborted
                        (model-join result.aborted step.facts))]
                    [_
                      (begin
                        (when
                          cleanup
                          (let
                            [read : ModelTransfer
                              (model-transfer
                                step.facts
                                (ModelOperation.Read)
                                (ModelPlace.Tail))]
                            (set! result.failed (or result.failed read.failed))))
                        (match edge
                          [(ModelExit.Return)
                            (set!
                              result.returned
                              (model-join result.returned step.facts))]
                          [(ModelExit.Break)
                            (set!
                              result.normal
                              (model-join result.normal step.facts))]
                          [_
                            (begin
                              (set!
                                result.header
                                (model-join result.header step.facts))
                              (set!
                                result.normal
                                (model-join result.normal step.facts)))]))])))
              (set! arm (+ arm 1)))
            (set! changed (not (model-equal? before result.header)))))
        (set! fuel (+ fuel 1)))
      (set! result.complete (not changed))
      result)))

(define (model-states-contained? [states : i64] [facts : ModelFacts]) : bool
  (let
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index 16))
        (when
          (model-state-member? states index)
          (set! ok (model-contains? facts (model-concrete index))))
        (set! index (+ index 1)))
      ok)))

(define (model-graph-agrees?
  [concrete : ModelConcreteGraph]
  [abstract : ModelAbstractGraph]) : bool
  (and
    concrete.complete
    abstract.complete
    (= concrete.failed abstract.failed)
    (model-states-contained? concrete.header abstract.header)
    (model-states-contained? concrete.normal abstract.normal)
    (model-states-contained? concrete.returned abstract.returned)
    (model-states-contained? concrete.aborted abstract.aborted)))

(define (model-graph-laws?) : bool
  (let
    [ok : bool true]
    [initial : i64 0]
    [checked : i64 0]
    (begin
      (while (and ok (< initial 16))
        (let
          [left : i64 0]
          (while (and ok (< left 120))
            (let
              [right : i64 0]
              (while (and ok (< right 120))
                (let
                  [retained : i64 0]
                  (while (and ok (< retained 2))
                    (let
                      [value : ModelConcrete (model-concrete initial)]
                      [concrete : ModelConcreteGraph
                        (model-execute-graph
                          value
                          (% left 24)
                          (model-exit (/ left 24))
                          (% right 24)
                          (model-exit (/ right 24))
                          (= retained 1)
                          32)]
                      [abstract : ModelAbstractGraph
                        (model-analyze-graph
                          value
                          (% left 24)
                          (model-exit (/ left 24))
                          (% right 24)
                          (model-exit (/ right 24))
                          (= retained 1)
                          32)]
                      (set!
                        ok
                        (model-require
                          (model-graph-agrees? concrete abstract)
                          "graph concrete/abstract agreement"
                          (+ (* initial 2) retained)
                          left
                          right))
                      (unless
                        ok
                        (io.println
                          "concrete: header={} normal={} returned={} aborted={} failed={} complete={}"
                          concrete.header
                          concrete.normal
                          concrete.returned
                          concrete.aborted
                          concrete.failed
                          concrete.complete)
                        (io.println
                          "abstract: header=({}, {}) normal=({}, {}) returned=({}, {}) aborted=({}, {}) failed={} complete={}"
                          abstract.header.definite
                          abstract.header.possible
                          abstract.normal.definite
                          abstract.normal.possible
                          abstract.returned.definite
                          abstract.returned.possible
                          abstract.aborted.definite
                          abstract.aborted.possible
                          abstract.failed
                          abstract.complete)))
                    (set! checked (+ checked 1))
                    (set! retained (+ retained 1))))
                (set! right (+ right 1))))
            (set! left (+ left 1))))
        (set! initial (+ initial 1)))
      (and
        ok
        (model-require
          (= checked 460800)
          "complete graph campaign"
          checked
          460800
          0)))))

(define (model-witnesses?) : bool
  (let
    [full : ModelConcrete (model-concrete 15)]
    [partial : ModelConcreteStep
      (model-step full (ModelOperation.Move) (ModelPlace.Left))]
    [shadow : ModelConcreteStep
      (model-step partial.value (ModelOperation.Initialize) (ModelPlace.Shadow))]
    [repaired : ModelConcreteStep
      (model-step shadow.value (ModelOperation.Initialize) (ModelPlace.Left))]
    [empty-budget : ModelAbstractGraph
      (model-analyze-graph full 0 (ModelExit.Abort) 0 (ModelExit.Abort) false 0)]
    [early-return : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Return)
        0
        (ModelExit.Return)
        false
        32)]
    [backedge : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Continue)
        0
        (ModelExit.Return)
        false
        32)]
    [break-exit : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Break)
        0
        (ModelExit.Return)
        false
        32)]
    [cleanup-return : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Return)
        0
        (ModelExit.Return)
        true
        32)]
    [cleanup-abort : ModelAbstractGraph
      (model-analyze-graph full 9 (ModelExit.Abort) 0 (ModelExit.Abort) true 32)]
    (model-require
      (and
        partial.valid
        (not (model-ready? partial.value (ModelPlace.Root)))
        (model-ready? partial.value (ModelPlace.Right))
        (not (model-ready? shadow.value (ModelPlace.Left)))
        (model-ready? repaired.value (ModelPlace.Root))
        (not empty-budget.complete)
        (not early-return.failed)
        (= early-return.normal.definite 15)
        backedge.failed
        (not break-exit.failed)
        (= break-exit.normal.definite 13)
        cleanup-return.failed
        (not cleanup-abort.failed))
      "SPEC nested move/shadow/reinit/exit witnesses"
      0
      0
      0)))

;; These deliberately wrong answers must be distinguishable from the oracle.
;; Each control names a semantic obligation and a concrete witness; agreement
;; between two compiler optimization levels is not used as an oracle.
;; Actual source edits are exercised separately by verify-ownership-model.sh.
(define (model-oracle-controls?) : bool
  (let
    [full : ModelConcrete (model-concrete 15)]
    [moved : ModelConcreteStep
      (model-step full (ModelOperation.Move) (ModelPlace.Left))]
    [point : ModelFacts (model-point full)]
    [bad-join : ModelFacts (ModelFacts true 15 15)]
    [cleanup : ModelConcreteGraph
      (model-execute-graph
        full
        9
        (ModelExit.Return)
        0
        (ModelExit.Return)
        true
        32)]
    [dropped-cleanup : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Return)
        0
        (ModelExit.Return)
        false
        32)]
    [loop : ModelConcreteGraph
      (model-execute-graph
        full
        9
        (ModelExit.Continue)
        0
        (ModelExit.Return)
        false
        32)]
    [dropped-backedge : ModelAbstractGraph
      (model-analyze-graph
        full
        9
        (ModelExit.Return)
        0
        (ModelExit.Return)
        false
        32)]
    [ok : bool true]
    [index : i64 0]
    (begin
      (while (and ok (< index 16))
        (set! ok (= (model-concrete-id (model-concrete index)) index))
        (set! index (+ index 1)))
      (model-require
        (and
          ok
          (not (model-contains? point moved.value))
          (not (model-contains? bad-join moved.value))
          (not (model-graph-agrees? cleanup dropped-cleanup))
          (not (model-graph-agrees? loop dropped-backedge)))
        "oracle detects lost move/unsafe join/omitted cleanup/dropped backedge"
        0
        0
        0))))

(test
  ownership-model-lattice-laws
  (test.assert-true (model-lattice-laws?) "finite ownership join laws"))

(test
  ownership-model-transfer-laws
  (test.assert-true (model-transfer-laws?) "finite ownership transfer laws"))

(test
  ownership-model-graph-laws
  (test.assert-true (model-graph-laws?) "finite ownership graph laws"))

(test
  ownership-model-spec-witnesses
  (test.assert-true (model-witnesses?) "ownership SPEC derivations"))

(test
  ownership-model-oracle-controls
  (test.assert-true (model-oracle-controls?) "finite model oracle controls"))

(define (main) : i64
  (if (and
    (model-lattice-laws?)
    (model-transfer-laws?)
    (model-witnesses?)
    (model-oracle-controls?)
    (model-graph-laws?))
    (begin
      (io.println
        "ownership-model-v1: lattice=82 concrete=16 places=6 operations=4 graphs=460800 passed")
      0)
    1))