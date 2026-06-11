(import "stdlib/hash.tl")

(import "stdlib/test.tl")

(define (assert-hash-range [value : i64] [message : String]) : unit
  (begin
    (assert-true (>= value 0) message)
    (assert-true (< value (hash-modulus)) message)))

(define (hash-test-string [key : String]) : i64
  (hash-string (& key)))

(define (hash-test-key-string-eq? [a : String] [b : String]) : bool
  (hash-key-string-eq? (& a) (& b)))

(define (assert-stable-values) : unit
  (let
    [empty : String ""]
    [a : String "a"]
    [ab : String "ab"]
    [abc : String "abc"]
    [abcd : String "abcd"]
    [abcdefgh : String "abcdefgh"]
    [ba : String "ba"]
    [a-newline-b : String "a\nb"]
    (begin
      (assert-i64-eq (hash-modulus) 2147483647 "hash modulus")
      (assert-i64-eq (hash-multiplier) 131 "hash multiplier")
      (assert-i64-eq (hash-normalize 2147483647) 0 "normalize modulus")
      (assert-i64-eq (hash-normalize -1) 2147483646 "normalize negative")
      (assert-i64-eq (hash-i64 42) 42 "hash-i64 positive")
      (assert-i64-eq (hash-i64 -42) 2147483605 "hash-i64 negative")
      (assert-i64-eq (hash-bool false) 0 "hash false")
      (assert-i64-eq (hash-bool true) 1 "hash true")
      (assert-i64-eq (hash-char #A') 65 "hash char")
      (assert-i64-eq (hash-char #\newline') 10 "hash newline")
      (assert-i64-eq (hash-combine 0 0) 1 "combine empty component")
      (assert-i64-eq (hash-combine 42 7) 5510 "combine stable")
      (assert-i64-eq (hash-test-string empty) 0 "hash empty string")
      (assert-i64-eq (hash-test-string a) 98 "hash one byte")
      (assert-i64-eq (hash-test-string ab) 12937 "hash two bytes")
      (assert-i64-eq (hash-test-string abc) 1694847 "hash three bytes")
      (assert-i64-eq (hash-test-string abcd) 222025058 "hash four bytes")
      (assert-i64-eq (hash-test-string abcdefgh) 1379066653 "hash eight bytes")
      (assert-i64-eq (hash-test-string ba) 13067 "hash order-sensitive string")
      (assert-i64-eq
        (hash-test-string a-newline-b)
        1683318
        "hash string newline"))))

(define (assert-equal-values-same-hash) : unit
  (let
    [abc : String "abc"]
    [a : String "a"]
    [bc : String "bc"]
    [joined : String (string-append a bc)]
    (begin
      (assert-i64-eq (hash-i64 42) (hash-i64 (+ 40 2)) "equal i64 hash")
      (assert-i64-eq (hash-bool true) (hash-bool (not false)) "equal bool hash")
      (assert-i64-eq
        (hash-char #A')
        (hash-char (string-ref "A" 0))
        "equal char hash")
      (assert-i64-eq
        (hash-test-string abc)
        (hash-test-string joined)
        "equal string hash"))))

(define (assert-key-equality) : unit
  (begin
    (assert-true (hash-key-i64-eq? 5 5) "i64 equality true")
    (assert-false (hash-key-i64-eq? 5 6) "i64 equality false")
    (assert-true (hash-key-bool-eq? true true) "bool equality true")
    (assert-false (hash-key-bool-eq? true false) "bool equality false")
    (assert-true (hash-key-char-eq? #x' #x') "char equality true")
    (assert-false (hash-key-char-eq? #x' #y') "char equality false")
    (assert-true
      (hash-test-key-string-eq? "same" (string-append "sa" "me"))
      "string equality true")
    (assert-false
      (hash-test-key-string-eq? "same" "different")
      "string equality false")))

(define (assert-collision-behavior) : unit
  (begin
    (assert-i64-eq (hash-i64 0) (hash-i64 2147483647) "i64 collision")
    (assert-false
      (hash-key-i64-eq? 0 2147483647)
      "colliding i64 keys still require equality")
    (assert-i64-eq (hash-combine 0 131) (hash-combine 1 0) "combine collision")
    (assert-false
      (hash-key-i64-eq? 0 1)
      "colliding combined seeds still require equality")))

(define (assert-ranges) : unit
  (let
    [empty : String ""]
    [edge : String "edge\ncase"]
    (begin
      (assert-hash-range (hash-i64 -9223372036854775808) "min i64 range")
      (assert-hash-range (hash-i64 9223372036854775807) "max i64 range")
      (assert-hash-range (hash-combine -1 -1) "combine range")
      (assert-hash-range (hash-test-string empty) "empty string range")
      (assert-hash-range (hash-test-string edge) "newline string range"))))

(define (main) : i64
  (begin
    (assert-stable-values)
    (assert-equal-values-same-hash)
    (assert-key-equality)
    (assert-collision-behavior)
    (assert-ranges)
    42))