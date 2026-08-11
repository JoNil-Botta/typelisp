; Capturing fixed arrays whose elements or fields contain aggregate storage
; (#631). Copy-only aggregate closures may return; String-containing arrays
; remain local because widening a non-Copy closure to `(-> ...)` loses its
; concrete ownership fact.
;; lint-allow: unused-import
(import stdlib.string)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Chunk
  (items (Array i64 3)))

(defstruct Names
  (items (Array String 2)))

(define (case-string-array) : bool
  (let
    [names : (Array String 2) (array "hello" "world!")]
    [f : (-> i64)
      (lambda () : i64
        (+
          (string.string-length (array-ref names 0))
          (string.string-length (array-ref names 1))))]
    (= (f) 11)))

(define (make-point-array-reader) : (-> i64)
  (let
    [points : (Array Point 2) (array (Point 10 11) (Point 20 1))]
    (lambda () : i64
      (+
        (struct-get (array-ref points 0) x)
        (+
          (struct-get (array-ref points 0) y)
          (+
            (struct-get (array-ref points 1) x)
            (struct-get (array-ref points 1) y)))))))

(define (case-point-array) : bool
  (= ((make-point-array-reader)) 42))

(define (case-nested-array) : bool
  (let
    [grid : (Array (Array String 2) 2)
      (array (array "ab" "c") (array "def" "ghij"))]
    [f : (-> i64)
      (lambda () : i64
        (+
          (string.string-length (array-ref (array-ref grid 0) 0))
          (+
            (string.string-length (array-ref (array-ref grid 0) 1))
            (+
              (string.string-length (array-ref (array-ref grid 1) 0))
              (string.string-length (array-ref (array-ref grid 1) 1))))))]
    (= (f) 10)))

(define (make-chunk-reader) : (-> i64)
  (let
    [chunk : Chunk (Chunk (array 40 1 1))]
    (lambda () : i64
      (+
        (array-ref (struct-get chunk items) 0)
        (+
          (array-ref (struct-get chunk items) 1)
          (array-ref (struct-get chunk items) 2))))))

(define (case-fixed-array-field) : bool
  (= ((make-chunk-reader)) 42))

(define (case-fixed-array-field-mutated-after-capture) : bool
  (let
    [chunk : Chunk (Chunk (array 42 1 1))]
    [f : (-> i64)
      (lambda () : i64
        (array-ref (struct-get chunk items) 0))]
    (begin
      (array-set! (struct-get chunk items) 0 5)
      (= (f) 42))))

(define (case-aggregate-array-field) : bool
  (let
    [names : Names (Names (array "four" "letters"))]
    [f : (-> i64)
      (lambda () : i64
        (+
          (string.string-length (array-ref (struct-get names items) 0))
          (string.string-length (array-ref (struct-get names items) 1))))]
    (= (f) 11)))

(define (main) : i64
  (begin
    (unless (case-string-array) (return 1))
    (unless (case-point-array) (return 2))
    (unless (case-nested-array) (return 3))
    (unless (case-fixed-array-field) (return 4))
    (unless (case-fixed-array-field-mutated-after-capture) (return 5))
    (unless (case-aggregate-array-field) (return 6))
    42))