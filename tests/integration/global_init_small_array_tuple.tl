;; #8488: small fixed-array and fixed-tuple RuntimeGlobal startup initializers
;; must keep the arena-pointer IR return contract (not reclassify <=16B
;; structural returns under integer/register-group ABI), preserve static
;; constant arrays on their static path, and support whole-global `set!`.
(define (minus-one) : i8
  -1)

(define (get-bool) : bool
  true)

(define (get-char) : char
  'z')

(define (get-f32) : f32
  2.5)

(define (get-i32) : i32
  9)

(define (get-i64) : i64
  6)

(define (get-str) : String
  "right")

(define a-i8 : (Array i8 4)
  (array (minus-one) 2 3 4))
(define a-bool : (Array bool 3)
  (array false (get-bool) false))
(define a-char : (Array char 3)
  (array 'a' (get-char) 'c'))
(define a-f32 : (Array f32 3)
  (array 1.5 (get-f32) 3.5))
(define a-i32 : (Array i32 3)
  (array 1 (get-i32) 3))
(define a-i64 : (Array i64 2)
  (array 5 (get-i64)))
(define a-str-lit : (Array String 2)
  (array "left" "right"))
(define a-str-call : (Array String 2)
  (array "left" (get-str)))
(define a-box : (Array (Box i64) 2)
  (array (box 3) (box 4)))
(define a-static : (Array i8 4)
  (array 10 20 30 40))
(define t-i8 : (Tuple i8 i8 i8 i8)
  (tuple (minus-one) 2 3 4))
(define t-f32 : (Tuple f32 f32 f32)
  (tuple 1.5 (get-f32) 3.5))
(define t-i64 : (Tuple i64 i64)
  (tuple 5 (get-i64)))
(define t-str : (Tuple String String)
  (tuple "ab" (get-str)))

(define (main) : i64
  (let
    [r0 : i64
      (+
        (cast (array-ref a-i8 0) : i64)
        (+
          (cast (array-ref a-i8 1) : i64)
          (+
            (if (array-ref a-bool 1)
              1
              0)
            (+
              (if (= (array-ref a-char 1) 'z')
                1
                0)
              (+
                (if (= (array-ref a-f32 1) 2.5)
                  1
                  0)
                (+
                  (cast (array-ref a-i32 1) : i64)
                  (+
                    (array-ref a-i64 1)
                    (+
                      (length (array-ref a-str-lit 0))
                      (+
                        (length (array-ref a-str-call 1))
                        (+
                          (deref (array-ref a-box 0))
                          (deref (array-ref a-box 1))))))))))))]
    [r1 : i64
      (+
        (cast (tuple-ref t-i8 1) : i64)
        (+
          (if (= (tuple-ref t-f32 1) 2.5)
            1
            0)
          (+ (tuple-ref t-i64 1) (length (tuple-ref t-str 0)))))]
    (set! a-i8 (array 7 8 9 10))
    (set! a-i64 (array 11 12))
    (set! a-str-call (array "x" "yz"))
    (set! a-static (array 1 2 3 4))
    (set! t-i8 (tuple 5 6 7 8))
    (set! t-i64 (tuple 1 2))
    (let
      [r2 : i64
        (+
          (cast (array-ref a-i8 2) : i64)
          (+
            (array-ref a-i64 1)
            (+
              (length (array-ref a-str-call 1))
              (+
                (cast (array-ref a-static 3) : i64)
                (+ (cast (tuple-ref t-i8 1) : i64) (tuple-ref t-i64 1))))))]
      ;; r0 = -1 + 2 + 1 + 1 + 1 + 9 + 6 + 4 + 5 + 3 + 4 = 35
      ;; r1 = 2 + 1 + 6 + 2 = 11
      ;; r2 = 9 + 12 + 2 + 4 + 6 + 2 = 35
      (if (and (= r0 35) (= r1 11) (= r2 35))
        42
        1))))