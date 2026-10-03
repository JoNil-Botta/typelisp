;; `size` and `State` share their names with declarations of the entry module
;; (macro_view_root_shadow.tl), and their parameter or payload is a generated
;; module's type. The entry module materializes that generated module first, so
;; `m` here starts as a lazy import. Each `view` call types the local bound
;; before it through this module's view (#8614).
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as m)

(defmacro (view [place : Expr]) : Expr
  place)

(defenum Slot
  (State i64 m.Map))

(define (size [t : m.Map]) : i64
  (m.get-value-or (& t) 1 7))

(define (bump [cache : m.Map]) : i64
  (let
    [n : i64 (size cache)]
    (view n)))

(define (slot-base [base : i64] [cache : m.Map]) : i64
  (let
    [slot : Slot (State base cache)]
    (match (view slot)
      [(State found _) found])))