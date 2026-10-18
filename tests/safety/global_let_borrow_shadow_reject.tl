;; refs #8750: a borrow of a global outlives local scopes only while no local
;; spells the global's name. A local that shadows the global gives its borrow
;; the same lifetime spelling, and that borrow dies with the local.
(defstruct GlobalLetShadowRec
  (value i64))

(define shadowed : GlobalLetShadowRec
  (GlobalLetShadowRec 1))

(define (global-let-shadow) : i64
  (let
    [outer (& shadowed)]
    (let
      [shadowed (GlobalLetShadowRec 42)]
      (set! outer (& shadowed)))
    outer.value))

(define (main) : i64
  (global-let-shadow))