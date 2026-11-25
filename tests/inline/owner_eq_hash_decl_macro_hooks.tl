;; owner_eq_hash_decl_macro_hooks.tl - hand-written owner hooks survive inline
;; test pruning when only a declaration macro call such as `(hash.gen T)` or
;; `(eq.gen T)` resolves them, with no generated-module import in the file.
(import stdlib.test)
(import stdlib.eq)
(import stdlib.hash)

(defstruct DeclHookPoint
  (x i64)
  (note i64))

;; Only `hash.gen` names this hook; no test calls it.
(define (eq-decl-hook-point
  [left : (& left DeclHookPoint)]
  [right : (& right DeclHookPoint)]) : bool
  (and (= left.x right.x) (= left.note right.note)))

(hash.gen DeclHookPoint)

(defstruct DeclHookInner
  (value i64))

;; Semantic equality: every inner value is equal.
(define (eq-decl-hook-inner
  [_left : (& left DeclHookInner)]
  [_right : (& right DeclHookInner)]) : bool
  true)

(defstruct DeclHookOuter
  (inner DeclHookInner)
  (tag i64))

(eq.gen DeclHookOuter)

(test
  owner-eq-hash-decl-macro-hooks
  (let
    [a : DeclHookPoint (DeclHookPoint 1 2)]
    [same : DeclHookPoint (DeclHookPoint 1 2)]
    [left : DeclHookOuter (DeclHookOuter (DeclHookInner 1) 5)]
    [right : DeclHookOuter (DeclHookOuter (DeclHookInner 2) 5)]
    [other : DeclHookOuter (DeclHookOuter (DeclHookInner 1) 6)]
    (test.assert-true
      (= (hash-decl-hook-point (& a)) (hash-decl-hook-point (& same)))
      "hash.gen resolves the hand-written eq hook")
    (test.assert-true
      (eq-decl-hook-outer (& left) (& right))
      "eq.gen calls the hand-written inner hook")
    (test.assert-false
      (eq-decl-hook-outer (& left) (& other))
      "eq.gen compares the remaining fields")))