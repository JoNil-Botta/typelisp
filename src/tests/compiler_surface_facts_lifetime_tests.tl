(import stdlib.arena)
(import stdlib.io)
(import compiler_surface_facts as facts)

(test
  surface-facts-publication-outlives-source-frontend
  (let
    [home : arena.Arena (arena.current)]
    (begin
      (facts.surface-typecheck-facts-clear!)
      (with-scratch
        (let
          [facts : facts.SurfaceTypecheckFacts
            (facts.SurfaceTypecheckFacts
              2
              3
              1
              1
              1
              (__tl_make-array 7)
              (__tl_make-array 11)
              (__tl_make-array 0))]
          (begin
            (unless
              (facts.surface-typecheck-facts-publish-composite! facts)
              (io.panic "source composite facts must be valid"))
            (in-arena home (facts.surface-typecheck-facts-retain-current!)))))
      (with-scratch
        (let
          [reuse : (__tl_dyn-array i64) (__tl_make-array i64 1048576)]
          (set! (array-ref reuse 0) 7797)))
      (let
        [facts : facts.SurfaceTypecheckFacts
          (facts.surface-typecheck-facts-current)]
        (begin
          (unless
            (and
              (facts.surface-typecheck-facts-active?)
              (facts.surface-typecheck-facts-composite-active?)
              (facts.surface-typecheck-facts-valid? facts)
              (= (array-ref facts.clone-decl-keys 0) 7)
              (= (array-ref facts.clone-root-keys 0) 11)
              (= (array-ref facts.clone-call-indices 0) 0))
            (io.panic "retired frontend invalidated its published facts"))
          (facts.surface-typecheck-facts-clear!))))))