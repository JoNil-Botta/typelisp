(import "stdlib/test.tl")

(import "stdlib/vector.tl")

(import "stdlib/sort.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (make-i64-vec1 [a : i64]) : I64Vec
  (i64-vec-push (i64-vec-new) a))

(define (make-i64-vec3 [a : i64] [b : i64] [c : i64]) : I64Vec
  (i64-vec-push (i64-vec-push (i64-vec-push (i64-vec-new) a) b) c))

(define (make-i64-vec5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : I64Vec
  (i64-vec-push
    (i64-vec-push
      (i64-vec-push (i64-vec-push (i64-vec-push (i64-vec-new) a) b) c)
      d)
    e))

(define (assert-i64-vec1 [v : I64Vec] [a : i64]) : unit
  (begin
    (assert-i64-eq (i64-vec-len v) 1 "i64 vec1 len")
    (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec1 0")))

(define (assert-i64-vec3 [v : I64Vec] [a : i64] [b : i64] [c : i64]) : unit
  (begin
    (assert-i64-eq (i64-vec-len v) 3 "i64 vec3 len")
    (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec3 0")
    (assert-i64-eq (i64-vec-get v 1 9999) b "i64 vec3 1")
    (assert-i64-eq (i64-vec-get v 2 9999) c "i64 vec3 2")))

(define (assert-i64-vec5
  [v : I64Vec]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]) : unit
  (begin
    (assert-i64-eq (i64-vec-len v) 5 "i64 vec5 len")
    (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec5 0")
    (assert-i64-eq (i64-vec-get v 1 9999) b "i64 vec5 1")
    (assert-i64-eq (i64-vec-get v 2 9999) c "i64 vec5 2")
    (assert-i64-eq (i64-vec-get v 3 9999) d "i64 vec5 3")
    (assert-i64-eq (i64-vec-get v 4 9999) e "i64 vec5 4")))

(define (make-string-vec1 [a : String]) : StringVec
  (string-vec-push (string-vec-new) a))

(define (make-string-vec4 [a : String] [b : String] [c : String] [d : String]) : StringVec
  (string-vec-push
    (string-vec-push (string-vec-push (string-vec-push (string-vec-new) a) b) c)
    d))

(define (assert-string-vec1 [v : StringVec] [a : String]) : unit
  (begin
    (assert-i64-eq (string-vec-len v) 1 "string vec1 len")
    (assert-owned-string-eq (string-vec-get v 0 "missing") a "string vec1 0")))

(define (assert-string-vec4
  [v : StringVec]
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : unit
  (begin
    (assert-i64-eq (string-vec-len v) 4 "string vec4 len")
    (assert-owned-string-eq (string-vec-get v 0 "missing") a "string vec4 0")
    (assert-owned-string-eq (string-vec-get v 1 "missing") b "string vec4 1")
    (assert-owned-string-eq (string-vec-get v 2 "missing") c "string vec4 2")
    (assert-owned-string-eq (string-vec-get v 3 "missing") d "string vec4 3")))

(define (assert-i64-sort-cases) : unit
  (begin
    (let
      [empty : I64Vec (i64-vec-sort! (i64-vec-new))]
      (begin
        (assert-i64-eq (i64-vec-len empty) 0 "empty i64 sort len")
        (assert-true (>= (i64-vec-capacity empty) 1) "empty i64 sort growable")))
    (assert-i64-vec1 (i64-vec-sort! (make-i64-vec1 7)) 7)
    (assert-i64-vec3 (i64-vec-sort! (make-i64-vec3 1 2 3)) 1 2 3)
    (assert-i64-vec5 (i64-vec-sort! (make-i64-vec5 5 4 3 2 1)) 1 2 3 4 5)
    (assert-i64-vec5 (i64-vec-sort! (make-i64-vec5 3 1 3 2 1)) 1 1 2 3 3)
    (assert-i64-vec5
      (i64-vec-sort! (make-i64-vec5 0 -10 5 -10 2))
      -10
      -10
      0
      2
      5)))

(define (assert-string-less-cases) : unit
  (begin
    (assert-true (sort-string-less? "" "a") "empty string sorts first")
    (assert-true (sort-string-less? "a" "aa") "prefix sorts first")
    (assert-true (sort-string-less? "alpha" "beta") "alpha before beta")
    (assert-false (sort-string-less? "beta" "alpha") "beta after alpha")
    (assert-false (sort-string-less? "same" "same") "equal is not less")))

(define (assert-string-sort-cases) : unit
  (begin
    (let
      [empty : StringVec (string-vec-sort! (string-vec-new))]
      (begin
        (assert-i64-eq (string-vec-len empty) 0 "empty string sort len")
        (assert-true
          (>= (string-vec-capacity empty) 1)
          "empty string sort growable")))
    (assert-string-vec1 (string-vec-sort! (make-string-vec1 "solo")) "solo")
    (assert-string-vec4
      (string-vec-sort! (make-string-vec4 "alpha" "bravo" "charlie" "delta"))
      "alpha"
      "bravo"
      "charlie"
      "delta")
    (assert-string-vec4
      (string-vec-sort! (make-string-vec4 "delta" "alpha" "charlie" "bravo"))
      "alpha"
      "bravo"
      "charlie"
      "delta")
    (assert-string-vec4
      (string-vec-sort! (make-string-vec4 "b" "aa" "a" ""))
      ""
      "a"
      "aa"
      "b")
    (assert-string-vec4
      (string-vec-sort! (make-string-vec4 "beta" "alpha" "beta" "alpha"))
      "alpha"
      "alpha"
      "beta"
      "beta")))

(define (main) : i64
  (begin
    (assert-i64-sort-cases)
    (assert-string-less-cases)
    (assert-string-sort-cases)
    42))