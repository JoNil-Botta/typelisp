;; vector_named_family_macro.tl - named generated vector-family coverage (#3305).
(import stdlib.test)
(import stdlib.vector)

(defstruct VecFamilyPoint
  (x i64)
  (y i64))

(defstruct VecFamilySpan
  (start i64)
  (len i64))

(define (vec-family-point-score [p : VecFamilyPoint]) : i64
  (+ (* (struct-get p x) 10) (struct-get p y)))

(define (vec-family-span-end [s : VecFamilySpan]) : i64
  (+ (struct-get s start) (struct-get s len)))

(vector.family VecFamilyPoint VecFamilyPointVec vec-family-point-vec)

(vector.family VecFamilySpan VecFamilySpanVec vec-family-span-vec)

(test
  named-vector-family-two-local-aggregate-families
  (let
    [points : VecFamilyPointVec (vec-family-point-vec-with-capacity 1)]
    [spans : VecFamilySpanVec (vec-family-span-vec-new)]
    (begin
      (vec-family-point-vec-push (&mut points) (VecFamilyPoint 1 2))
      (vec-family-point-vec-push (&mut points) (VecFamilyPoint 3 4))
      (vec-family-span-vec-push (&mut spans) (VecFamilySpan 5 7))
      (test.assert-i64-eq
        (vec-family-point-vec-len (& points))
        2
        "point family len")
      (test.assert-i64-eq
        (vec-family-point-vec-capacity (& points))
        2
        "point family grew")
      (test.assert-i64-eq
        (vec-family-point-score
          (vec-family-point-vec-get (& points) 1 (VecFamilyPoint 0 0)))
        34
        "point family get")
      (vec-family-point-vec-set! (&mut points) 0 (VecFamilyPoint 9 8))
      (test.assert-i64-eq
        (vec-family-point-score
          (vec-family-point-vec-get (& points) 0 (VecFamilyPoint 0 0)))
        98
        "point family set!")
      (test.assert-i64-eq
        (vec-family-span-vec-len (& spans))
        1
        "span family len")
      (test.assert-i64-eq
        (vec-family-span-vec-capacity (& spans))
        4
        "span family default capacity")
      (test.assert-i64-eq
        (vec-family-span-end
          (vec-family-span-vec-get (& spans) 0 (VecFamilySpan 0 0)))
        12
        "span family get"))))