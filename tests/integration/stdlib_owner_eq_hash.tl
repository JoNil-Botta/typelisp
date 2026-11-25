;; Owner-side `(eq.gen T)` / `(hash.gen T)` hooks and the Eq/Hash law (#7034,
;; #7049). Generated hooks compare and hash structs, enums and nested nominal
;; members through shared borrows; repeating a generator is idempotent; a
;; hand-written semantic pair is used by the adapters, a HashMap and a Set.
;; Equal values hash equally across structs, enums, nested nominals, tuples,
;; arrays and String, including distinct-but-equal values. Exits 42, or the
;; number of the failed check.
(import stdlib.clone)
(import stdlib.eq)
(import stdlib.hash)
(import stdlib.hashmap)
(import stdlib.set)
(import stdlib.string)

(defstruct Point
  (x i64)
  (label String))

(eq.gen Point)

(hash.gen Point)

;; Repeating the identical generator call is idempotent.
(eq.gen Point)

(hash.gen Point)

(stdlib.clone.gen-clone Point)

(defenum Shape
  (Empty)
  (Dot Point)
  (Pair (Tuple i64 String))
  (Grid (Array Point 2)))

(eq.gen Shape)

(hash.gen Shape)

;; A semantic key: versions are equal when their major numbers are, whatever
;; the note says. The hand-written pair keeps the Eq/Hash law.
(defstruct Version
  (major i64)
  (note String))

(define (eq-version [left : (& left Version)] [right : (& right Version)]) : bool
  (= left.major right.major))

(define (hash-version [value : (& value Version)]) : i64
  (hash.i64 value.major))

(stdlib.clone.gen-clone Version)

(import (eq.eq Shape) as shape_eq)
(import (hash.hash Shape) as shape_hash)
(import (eq.eq (Tuple Point (Array i64 2))) as tuple_eq)
(import (hash.hash (Tuple Point (Array i64 2))) as tuple_hash)
(import (eq.eq Version) as version_eq)
(import (hash.hash Version) as version_hash)
(import (hashmap.hashmap Version i64) as version_map)
(import (set.set Version) as version_set)

(define (copied [text : String]) : String
  (string.append "" text))

(define (generated-ok?) : bool
  (let
    [a : Shape (Shape.Dot (Point 1 "a"))]
    [same : Shape (Shape.Dot (Point 1 (copied "a")))]
    [other : Shape (Shape.Dot (Point 2 "a"))]
    [grid : Shape (Shape.Grid (array (Point 1 "a") (Point 2 "b")))]
    [grid-same : Shape
      (Shape.Grid (array (Point 1 (copied "a")) (Point 2 "b")))]
    [pair : Shape (Shape.Pair (tuple 3 "p"))]
    [pair-same : Shape (Shape.Pair (tuple 3 (copied "p")))]
    [empty : Shape (Shape.Empty)]
    (and
      (eq-shape (& a) (& same))
      (shape_eq.eq (& grid) (& grid-same))
      (shape_eq.eq? (& pair) (& pair-same))
      (not (eq-shape (& a) (& other)))
      (not (eq-shape (& a) (& empty)))
      (not (shape_eq.eq (& grid) (& a)))
      (= (hash-shape (& a)) (shape_hash.hash (& same)))
      (= (shape_hash.hash (& grid)) (shape_hash.hash (& grid-same)))
      (= (shape_hash.hash (& pair)) (shape_hash.hash (& pair-same)))
      (!= (hash-shape (& a)) (hash-shape (& other)))
      (!= (hash-shape (& a)) (hash-shape (& empty))))))

(define (structural-ok?) : bool
  (let
    [left : (Tuple Point (Array i64 2)) (tuple (Point 5 "t") (array 1 2))]
    [right : (Tuple Point (Array i64 2))
      (tuple (Point 5 (copied "t")) (array 1 2))]
    [other : (Tuple Point (Array i64 2)) (tuple (Point 5 "t") (array 2 1))]
    (and
      (tuple_eq.eq (& left) (& right))
      (not (tuple_eq.eq (& left) (& other)))
      (= (tuple_hash.hash (& left)) (tuple_hash.hash (& right)))
      (!= (tuple_hash.hash (& left)) (tuple_hash.hash (& other))))))

(define (semantic-ok?) : bool
  (let
    [one : Version (Version 1 "first")]
    [one-later : Version (Version 1 "patched")]
    [two : Version (Version 2 "first")]
    [m : version_map.Map (version_map.new)]
    [s : version_set.Set (version_set.new)]
    (version_map.insert! m (Version 1 "first") 10)
    (version_map.insert! m (Version 1 "patched") 11)
    (version_set.insert! s (Version 1 "first"))
    (version_set.insert! s (Version 1 "patched"))
    (version_set.insert! s (Version 2 "first"))
    (and
      (version_eq.eq (& one) (& one-later))
      (not (version_eq.eq (& one) (& two)))
      (= (version_hash.hash (& one)) (version_hash.hash (& one-later)))
      (= (version_map.len (& m)) 1)
      (=
        (version_map.lookup-value-or (version_map.get (& m) (Version 1 "x")) -1)
        11)
      (= (version_set.len (& s)) 2)
      (version_set.contains-borrowed? (& s) (& one-later)))))

(define (main) : i64
  (cond
    [(not (generated-ok?)) 1]
    [(not (structural-ok?)) 2]
    [(not (semantic-ok?)) 3]
    [else 42]))