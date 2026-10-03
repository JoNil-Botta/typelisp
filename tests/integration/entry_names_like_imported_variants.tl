;; Entry-module declarations may reuse the bare names of variants in imported
;; modules (#8582): unqualified lookup here never searches imports, so `Ok`,
;; `Fail` and `Done` below are this module's own struct, function and struct,
;; while the imported variants stay reachable qualified.
(import entry_names_like_imported_variants_dep as dep)
(import stdlib.iterator)

(defstruct Ok
  (v i64))

;; lint-allow: function-name-case -- deliberately spelled like dep's variant
(define (Fail [x : i64]) : i64
  (+ x 1))

(defstruct Done
  (v i64))

(define (main) : i64
  (let
    [ok : Ok (Ok 30)]
    [done : Done (Done 2)]
    [qualified : i64
      (match (dep.Outcome.Ok 1)
        [(dep.Outcome.Ok v) v]
        [(dep.Outcome.Fail _) 0])]
    [ended : bool
      (match (iterator.IntoNext.Done)
        [(iterator.IntoNext.Done) true]
        [_ false])]
    (if ended
      (+ ok.v done.v (dep.unwrap (dep.wrap 4)) (Fail 4) qualified)
      1)))