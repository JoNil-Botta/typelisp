;: Non-Copy globals are permanent places: declarations, borrows, mutation,
;: replacement, and reads of Copy values/projections remain legal.
(import stdlib.array)
(import stdlib.string)

(defstruct GlobalOwner
  (text String)
  (number i64))

(define global-text : String
  "hello")

(define global-fixed-owners : (Array String 2)
  (array "left" "right"))

(define global-items : (__tl_dyn-array i64)
  (array.make-array i64 2))

(define global-box : (Box i64)
  (box 40))

(define global-owner : GlobalOwner
  (GlobalOwner "nested" 2))

(define global-number : i64
  20)

(define global-fixed-copy : (Array i64 2)
  (array 20 22))

(define (text-length [text : (& text str)]) : i64
  (string.string-length text))

(define (fixed-sum [values : (Array i64 2)]) : i64
  (+ (array-ref values 0) (array-ref values 1)))

(define (main) : i64
  (let
    [explicit : i64 (string.string-length (& global-text))]
    [automatic : i64 (text-length global-text)]
    [copied : i64 global-number]
    [projected : i64 (struct-get global-owner number)]
    [fixed-copy : i64 (fixed-sum global-fixed-copy)]
    (begin
      (array-set! global-items 0 42)
      (set! (box-get global-box) (+ copied projected))
      (set! global-text "replaced")
      (+
        explicit
        (+ automatic (+ fixed-copy (array-ref global-items 0)))))))
