(import "stdlib/string.tl")

(defenum Box
  (BoxI i64))

(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [mk-string : (-> String)
      (lambda () : String
        "hello")]
    [mk-enum : (-> Box)
      (lambda () : Box
        (BoxI 11))]
    [mk-array : (-> (Array i64))
      (lambda () : (Array i64)
        (make-array i64 13))]
    [mk-struct : (-> Pair)
      (lambda () : Pair
        (Pair 1 13))]
    (+
      (string-length (mk-string))
      (+
        (match (mk-enum)
          [(BoxI n) n])
        (+ (array-length (mk-array)) (struct-get (mk-struct) y))))))
