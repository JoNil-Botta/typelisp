(module enum_constructor_owner_layout)

(import enum_constructor_owner_defs as owner)
(import stdlib.string)

(defstruct Pair
  (left i64)
  (right i64))

(defstruct Small
  (value i64))

(defstruct Label
  (text String)
  (extra i64))

(defenum Item
  (PairItem Pair)
  (LabelItem Label))

(defenum Scalar
  (Empty)
  (SmallItem Small))

(defstruct Holder
  (before i64)
  (item Item)
  (after i64))

(defenum Outer
  (Wrapped Item))

;; Direct calls require a value; returns and nested destinations also exercise
;; the constructor path that writes into an existing aggregate/result slot.
(define (make-item) : Item
  (PairItem (Pair 20 22)))

(define (owned-score [item : Item]) : i64
  (match item
    [(PairItem (Pair left right)) (+ left right)]
    [(LabelItem (Label text extra)) (+ (string.string-length text) extra)]))

(define (borrowed-score [item : (& item Item)]) : i64
  (match item
    [(PairItem pair) (+ pair.left pair.right)]
    [(LabelItem (Label text extra)) (+ (string.string-length text) extra)]))

(define (nested-score [item : (& item Outer)]) : i64
  (match item
    [(Wrapped (PairItem (Pair left right))) (+ left right)]
    [_ 0]))

(define (scalar-score [item : Scalar]) : i64
  (match item
    [(Empty) 0]
    [(SmallItem (Small value)) value]))

(define (borrowed-scalar-score [item : (& item Scalar)]) : i64
  (match item
    [(Empty) 0]
    [(SmallItem small) small.value]))

(define (imported-score [item : owner.Item]) : i64
  (match item
    [(PairItem (owner.Pair marker left right))
      (if marker
        (+ left right)
        0)]
    [(LabelItem (owner.Label before text extra))
      (+ before (string.string-length text) extra)]))

(define (borrowed-imported-score [item : (& item owner.Item)]) : i64
  (match item
    [(PairItem pair)
      (if pair.marker
        (+ pair.left pair.right)
        0)]
    [(LabelItem (owner.Label before text extra))
      (+ before (string.string-length text) extra)]))

(define (main) : i64
  (let
    [item : Item (make-item)]
    [label : Item (LabelItem (Label "abc" 39))]
    [scalar : Scalar (SmallItem (Small 42))]
    [holder : Holder (Holder 7 (PairItem (Pair 20 22)) 9)]
    [pair : (Tuple i64 Item) (tuple 7 (PairItem (Pair 20 22)))]
    [items : (Array Item 2)
      (array (PairItem (Pair 20 22)) (LabelItem (Label "abc" 39)))]
    [boxed : (Box Item) (box (PairItem (Pair 20 22)))]
    [outer : Outer (Wrapped (PairItem (Pair 20 22)))]
    [foreign : owner.Item (owner.Item.PairItem (owner.Pair true 20 22))]
    [foreign-label : owner.Item (owner.Item.LabelItem (owner.Label 1 "abc" 38))]
    [foreign-holder : owner.Holder (owner.Holder 7 (owner.Pair true 20 22) 9)]
    (unless (= (owned-score (PairItem (Pair 20 22))) 42) (return 1))
    (unless (= (owned-score (LabelItem (Label "abc" 39))) 42) (return 2))
    (unless (= (borrowed-score (& item)) 42) (return 3))
    (unless (= (borrowed-score (& label)) 42) (return 4))
    (unless (= (scalar-score (SmallItem (Small 42))) 42) (return 5))
    (unless (= (borrowed-scalar-score (& scalar)) 42) (return 6))
    (unless (= (borrowed-score (& holder.item)) 42) (return 7))
    (unless (and (= holder.before 7) (= holder.after 9)) (return 8))
    (unless (= (borrowed-score (& (tuple-ref pair 1))) 42) (return 9))
    (unless (= (tuple-ref pair 0) 7) (return 10))
    (unless (= (borrowed-score (& (array-ref items 0))) 42) (return 11))
    (unless (= (borrowed-score (& (array-ref items 1))) 42) (return 12))
    (unless (= (borrowed-score (& (deref boxed))) 42) (return 13))
    (unless (= (nested-score (& outer)) 42) (return 14))
    (unless (= (borrowed-imported-score (& foreign)) 42) (return 15))
    (unless (= (borrowed-imported-score (& foreign-label)) 42) (return 16))
    (unless
      (= (imported-score (owner.Item.PairItem (owner.Pair true 20 22))) 42)
      (return 17))
    (unless
      (= (imported-score (owner.Item.LabelItem (owner.Label 1 "abc" 38))) 42)
      (return 18))
    (unless
      (and
        (= foreign-holder.before 7)
        foreign-holder.pair.marker
        (= foreign-holder.pair.left 20)
        (= foreign-holder.pair.right 22)
        (= foreign-holder.after 9))
      (return 19))
    42))