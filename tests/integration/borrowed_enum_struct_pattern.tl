(import struct_match_pattern_geom as geom)
(import stdlib.io)

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

(define (small-score [item : (& item SmallItem)]) : i64
  (match item
    [(Value (Small code amount))
      (+ (cast (deref code) : i64) (cast (deref amount) : i64))]
    [(Empty) 0]))

(define (point-score [point : (& point Point)]) : i64
  (+ point.x point.y))

(define (score [item : (& item Item)]) : i64
  (match item
    [(Named tag (Details text (Point x y) (array first _) (tuple _ last)) extra)
      (+
        (cast (deref tag) : i64)
        (__tl_string_length text)
        (deref x)
        (deref y)
        (deref first)
        (deref last)
        (deref extra))]
    [(Empty) 0]))

(define (owner-score [item : Item]) : i64
  (let
    [first : i64
      (match (& item)
        [(Named _ (Details text (Point x _) _ _) _)
          (+ (__tl_string_length text) (deref x))]
        [(Empty) 0])]
    (+ first (score (& item)))))

(define (whole-field-score [item : (& item Item)]) : i64
  (match item
    [(Named _ (Details _ point _ _) _) (point-score point)]
    [(Empty) 0]))

(define (owned-score [item : Item]) : i64
  (match item
    [(Named tag (Details text (Point x y) (array first _) (tuple _ last)) extra)
      (+ (cast tag : i64) (__tl_string_length text) x y first last extra)]
    [(Empty) 0]))

(define (qualified-score [item : (& item Qualified)]) : i64
  (match item
    [(At (geom.QPoint x y)) (+ (deref x) (deref y))]))

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
    (unless (= (small-score (& small)) 42) (return 1))
    (unless (= (score (& item)) 42) (return 2))
    (unless (= (owner-score (make-item)) 55) (return 3))
    (unless (= (whole-field-score (& item)) 30) (return 4))
    (unless (= (owned-score (make-item)) 42) (return 5))
    (unless (= (qualified-score (& qualified)) 42) (return 6))
    (let
      [empty : Item Empty]
      [small-empty : SmallItem SmallItem.Empty]
      (unless (= (score (& empty)) 0) (return 7))
      (unless (= (small-score (& small-empty)) 0) (return 8)))
    42))

(define (main) : i64
  (exercise))

(test
  borrowed-enum-struct-pattern
  (unless
    (= (exercise) 42)
    (io.panic "borrowed enum struct pattern result mismatch")))