;; A header-less root control uses the provider's full module path. Its local
;; types have distinct names because root type-name collisions are rejected.
(import enum_constructor_owner_defs as owner)

(defstruct LocalPair
  (left i64)
  (right i64))

(defstruct LocalSmall
  (value i64))

(defenum LocalItem
  (LocalPairItem LocalPair)
  (LocalSmallItem LocalSmall))

(defstruct LocalHolder
  (item LocalItem)
  (pair LocalPair))

(define (owned-score [item : LocalItem]) : i64
  (match item
    [(LocalPairItem (LocalPair left right)) (+ left right)]
    [(LocalSmallItem (LocalSmall value)) value]))

(define (borrowed-score [item : (& item LocalItem)]) : i64
  (match item
    [(LocalPairItem (LocalPair left right)) (+ left right)]
    [(LocalSmallItem small) small.value]))

(define (main) : i64
  (let
    [item : LocalItem (LocalPairItem (LocalPair 20 22))]
    [holder : LocalHolder
      (LocalHolder (LocalSmallItem (LocalSmall 42)) (LocalPair 20 22))]
    [foreign : owner.Scalar
      (enum_constructor_owner_defs.Scalar.SmallItem
        (enum_constructor_owner_defs.Small 10 20 12))]
    (unless (= (borrowed-score (& item)) 42) (return 1))
    (unless (= (owned-score (LocalPairItem (LocalPair 20 22))) 42) (return 2))
    (unless (= (borrowed-score (& holder.item)) 42) (return 3))
    (unless (= (+ holder.pair.left holder.pair.right) 42) (return 4))
    (match foreign
      [(SmallItem (enum_constructor_owner_defs.Small before value after))
        (+ before value after)]
      [(Empty) 5])))