;; The provider's exports are not final until its generator has run, so the
;; loader defers this check; the completed expansion must still reject the
;; missing item even though nothing uses it.
(import source_selected_generated_provider.nothing as value)

(define (main) : i64
  0)