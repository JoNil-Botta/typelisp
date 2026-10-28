(import struct_match_pattern_geom as geom)
(import stdlib.string)

(defstruct Small
  (code u8)
  (amount u32))

(defenum SmallItem
  (Value Small)
  (Empty))

(defstruct Point
  (x i64)
  (y i64))

(defstruct Details
  (text String)
  (point Point)
  (slots (Array i64 2))
  (pair (Tuple i64 i64)))

(defenum Item
  (Named u8 Details i64)
  (Empty))

(defenum Qualified
  (At geom.QPoint))

(defenum Nested
  (Wrap Item)
  (Empty))

(defenum Siblings
  (Both String Point Details Point String)
  (Empty))

(defstruct UnitField
  (ignored unit)
  (value u8))

(defenum Boundary
  (Value UnitField)
  (Empty))

(define (small-score [item : (& item SmallItem)]) : i64
  (match item
    [(Value (Small code amount)) (+ (cast code : i64) (cast amount : i64))]
    [(Empty) 0]))

(define (point-score [point : (& point Point)]) : i64
  (+ point.x point.y))

(define (score [item : (& item Item)]) : i64
  (match item
    [(Named tag (Details text (Point x y) (array first _) (tuple _ last)) extra)
      (+ (cast tag : i64) (string.string-length text) x y first last extra)]
    [(Empty) 0]))

(define (owner-score [item : Item]) : i64
  (let
    [first : i64
      (match (& item)
        [(Named _ (Details text (Point x _) _ _) _)
          (+ (string.string-length text) x)]
        [(Empty) 0])]
    (+ first (score (& item)))))

(define (whole-field-score [item : (& item Item)]) : i64
  (match item
    [(Named _ (Details _ point _ _) _) (point-score point)]
    [(Empty) 0]))

(define (owned-score [item : Item]) : i64
  (match item
    [(Named tag (Details text (Point x y) (array first _) (tuple _ last)) extra)
      (+ (cast tag : i64) (string.string-length text) x y first last extra)]
    [(Empty) 0]))

(define (qualified-score [item : (& item Qualified)]) : i64
  (match item
    [(At (geom.QPoint x y)) (+ x y)]))

(define (nested-score [item : (& item Nested)]) : i64
  (match item
    [(Wrap
        (Named
          tag
          (Details text (Point x y) (array first _) (tuple _ last))
          extra))
      (if (string.eq text "abc")
        (+ (cast tag : i64) (string.string-length text) x y first last extra)
        1)]
    [_ 0]))

(define (sibling-score [item : (& item Siblings)]) : i64
  (match item
    [(Both before (Point a b) (Details text point _ _) (Point c d) after)
      (if (and
        (string.eq before "before")
        (string.eq text "abc")
        (string.eq after ""))
        (+ a b (point-score point) c d (string.string-length text))
        1)]
    [(Empty) 0]))

(define (owned-sibling-score [item : Siblings]) : i64
  (match item
    [(Both before (Point a b) (Details text (Point x y) _ _) (Point c d) after)
      (if (and
        (string.eq before "before")
        (string.eq text "abc")
        (string.eq after ""))
        (+ a b x y c d (string.string-length text))
        1)]
    [(Empty) 0]))

(define (boundary-score [item : (& item Boundary)]) : i64
  (match item
    [(Value (UnitField _ value)) (cast value : i64)]
    [(Empty) 0]))

(define (make-siblings) : Siblings
  (Both
    "before"
    (Point 1 2)
    (Details "abc" (Point 10 20) (array 0 0) (tuple 0 0))
    (Point 2 4)
    ""))

(define (copy-snapshot) : i64
  (let
    [item : SmallItem (Value (Small (cast 2 : u8) (cast 40 : u32)))]
    (match (& item)
      [(Value (Small code amount))
        (set! item (Value (Small (cast 0 : u8) (cast 0 : u32))))
        (+ (cast code : i64) (cast amount : i64))]
      [(Empty) 0])))

(define (make-item) : Item
  (Named
    (cast 1 : u8)
    (Details "abc" (Point 10 20) (array 2 100) (tuple 200 4))
    2))

(define (exercise) : i64
  (let
    [small : SmallItem (Value (Small (cast 2 : u8) (cast 40 : u32)))]
    [item : Item (make-item)]
    [qualified : Qualified (At (geom.QPoint 19 23))]
    [nested : Nested (Wrap (make-item))]
    [siblings : Siblings (make-siblings)]
    [boundary : Boundary (Value (UnitField unit (cast 42 : u8)))]
    (unless (= (small-score (& small)) 42) (return 1))
    (unless (= (score (& item)) 42) (return 2))
    (unless (= (owner-score (make-item)) 55) (return 3))
    (unless (= (whole-field-score (& item)) 30) (return 4))
    (unless (= (owned-score (make-item)) 42) (return 5))
    (unless (= (qualified-score (& qualified)) 42) (return 6))
    (unless (= (nested-score (& nested)) 42) (return 9))
    (unless (= (sibling-score (& siblings)) 42) (return 10))
    (unless (= (owned-sibling-score (make-siblings)) 42) (return 11))
    (unless (= (boundary-score (& boundary)) 42) (return 12))
    (unless (= (score (& item)) 42) (return 13))
    (unless (= (copy-snapshot) 42) (return 14))
    (let
      [empty : Item Empty]
      [small-empty : SmallItem SmallItem.Empty]
      [nested-empty : Nested (Wrap Item.Empty)]
      [siblings-empty : Siblings Siblings.Empty]
      (unless (= (score (& empty)) 0) (return 7))
      (unless (= (small-score (& small-empty)) 0) (return 8))
      (unless (= (nested-score (& nested-empty)) 0) (return 15))
      (unless (= (sibling-score (& siblings-empty)) 0) (return 16)))
    42))

(define (main) : i64
  (exercise))