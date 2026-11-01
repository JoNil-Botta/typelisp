;; Discriminating controls for actual isolated edits of the abstract model.
;; The source mutation harness changes main.tl, never this witness or its
;; concrete interpreter. These exact expected states follow from the other
;; leaves remaining initialized after moving Left and the specified exit rules.
(import main as model)
(import stdlib.io)

(define (model-mutation-controls?) : bool
  (let
    [full : model.ModelConcrete (model.model-concrete 15)]
    [moved : model.ModelTransfer
      (model.model-transfer
        (model.ModelFacts true 15 15)
        model.ModelOperation.Move
        model.ModelPlace.Left)]
    [joined : model.ModelFacts
      (model.model-join
        (model.ModelFacts true 15 15)
        (model.ModelFacts true 13 13))]
    [cleanup : model.ModelAbstractGraph
      (model.model-analyze-graph
        full
        9
        model.ModelExit.Return
        0
        model.ModelExit.Return
        true
        32)]
    [backedge : model.ModelAbstractGraph
      (model.model-analyze-graph
        full
        9
        model.ModelExit.Continue
        0
        model.ModelExit.Return
        false
        32)]
    (cond
      [(not
          (and
            moved.facts.reachable
            (= moved.facts.definite 13)
            (= moved.facts.possible 13)
            (not moved.failed)))
        (begin
          (io.println "ownership-model mutation mismatch: move")
          false)]
      [(not
          (and joined.reachable (= joined.definite 13) (= joined.possible 15)))
        (begin
          (io.println "ownership-model mutation mismatch: join")
          false)]
      [(not (and cleanup.complete cleanup.failed))
        (begin
          (io.println "ownership-model mutation mismatch: cleanup")
          false)]
      [(not (and backedge.complete backedge.failed))
        (begin
          (io.println "ownership-model mutation mismatch: backedge")
          false)]
      [else true])))

(define (main) : i64
  (if (model-mutation-controls?)
    (begin
      (io.println "ownership-model mutation controls passed")
      0)
    1))