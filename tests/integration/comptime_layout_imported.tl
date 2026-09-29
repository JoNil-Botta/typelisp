;; Compile-time layout queries on imported nominal types resolve through the
;; import like an ordinary annotation does (#8112): an alias and a module-name
;; qualification reach the same declaration, and a same-named type in another
;; module keeps its own layout. Every answer is compared with a local
;; declaration of the same shape.
(import comptime_layout_imported_dep as dep)
(import comptime_layout_imported_other)

(defstruct LocalPoint
  (x i64)
  (y i64))

(defstruct LocalSegment
  (from LocalPoint)
  (to LocalPoint))

(defstruct LocalCPoint
  (:repr c)
  (tag u8)
  (y i64))

(defenum LocalShape
  (Dot)
  (Box LocalPoint))

(defstruct LocalNarrow
  (x i8))

(define (main) : i64
  (if (and
    (=
      (comptime (size-of (type dep.Point)))
      (comptime (size-of (type LocalPoint))))
    (=
      (comptime (size-of (type comptime_layout_imported_dep.Point)))
      (comptime (size-of (type LocalPoint))))
    (=
      (comptime (align-of (type dep.Point)))
      (comptime (align-of (type LocalPoint))))
    (=
      (comptime (size-of (type dep.Segment)))
      (comptime (size-of (type LocalSegment))))
    (=
      (comptime (offset-of (type dep.CPoint) y))
      (comptime (offset-of (type LocalCPoint) y)))
    (=
      (comptime (size-of (type dep.CPoint)))
      (comptime (size-of (type LocalCPoint))))
    (=
      (comptime (size-of (type dep.Shape)))
      (comptime (size-of (type LocalShape))))
    (=
      (comptime (align-of (type dep.Shape)))
      (comptime (align-of (type LocalShape))))
    (=
      (comptime (size-of (type comptime_layout_imported_other.Point)))
      (comptime (size-of (type LocalNarrow))))
    (not
      (=
        (comptime (size-of (type comptime_layout_imported_other.Point)))
        (comptime (size-of (type dep.Point)))))
    (=
      (comptime (size-of (type (Array dep.Point 3))))
      (* 3 (comptime (size-of (type LocalPoint))))))
    42
    1))