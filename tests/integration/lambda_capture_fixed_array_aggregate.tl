; Capturing fixed arrays whose elements or fields contain aggregate storage

; (#631). Returned closures read after the creator frame has gone away, so each

; case only passes if capture snapshots fixed-array storage and rewrites nested

; aggregate handles onto the heap.

(defstruct Point
  (x i64)
  (y i64))

(defstruct Chunk
  (items (Array i64 3)))

(defstruct Names
  (items (Array String 2)))

(define (make-string-array-reader) : (-> i64)
  (let ([names : (Array String 2) (array "hello" "world!")])
    (lambda
      ()
      :
      i64
      (+
        (string-length (array-ref names 0))
        (string-length (array-ref names 1))))))

(define (case-string-array) : bool
  (= ((make-string-array-reader)) 11))

(define (make-point-array-reader) : (-> i64)
  (let ([points : (Array Point 2) (array (Point 10 11) (Point 20 1))])
    (lambda
      ()
      :
      i64
      (+
        (struct-get (array-ref points 0) x)
        (+
          (struct-get (array-ref points 0) y)
          (+
            (struct-get (array-ref points 1) x)
            (struct-get (array-ref points 1) y)))))))

(define (case-point-array) : bool
  (= ((make-point-array-reader)) 42))

(define (make-nested-array-reader) : (-> i64)
  (let ([grid : (Array (Array String 2) 2)
    (array (array "ab" "c") (array "def" "ghij"))])
    (lambda
      ()
      :
      i64
      (+
        (string-length (array-ref (array-ref grid 0) 0))
        (+
          (string-length (array-ref (array-ref grid 0) 1))
          (+
            (string-length (array-ref (array-ref grid 1) 0))
            (string-length (array-ref (array-ref grid 1) 1))))))))

(define (case-nested-array) : bool
  (= ((make-nested-array-reader)) 10))

(define (make-chunk-reader) : (-> i64)
  (let ([chunk : Chunk (Chunk (array 40 1 1))])
    (lambda
      ()
      :
      i64
      (+
        (array-ref (struct-get chunk items) 0)
        (+
          (array-ref (struct-get chunk items) 1)
          (array-ref (struct-get chunk items) 2))))))

(define (case-fixed-array-field) : bool
  (= ((make-chunk-reader)) 42))

(define (make-names-reader) : (-> i64)
  (let ([names : Names (Names (array "four" "letters"))])
    (lambda
      ()
      :
      i64
      (+
        (string-length (array-ref (struct-get names items) 0))
        (string-length (array-ref (struct-get names items) 1))))))

(define (case-aggregate-array-field) : bool
  (= ((make-names-reader)) 11))

(define (main) : i64
  (if (case-string-array)
    (if (case-point-array)
      (if (case-nested-array)
        (if (case-fixed-array-field)
          (if (case-aggregate-array-field)
            42
            5)
          4)
        3)
      2)
    1))