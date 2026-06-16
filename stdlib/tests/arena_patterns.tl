(import "stdlib/arena.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (scratch-temporary-score [seed : i64]) : i64
  (with-arena
    scratch
    (let
      [prefix : String "scratch:"]
      [seed-text : String (int->string seed)]
      [text : String (string-append-borrowed (& prefix) (& seed-text))]
      (string-length (& text)))))

(define (scratch-clone-message [scratch : i64] [seed : i64]) : String
  (with-escape
    scratch
    (let
      [prefix : String "kept:"]
      [seed-text : String (int->string seed)]
      (string-append-borrowed (& prefix) (& seed-text)))))

(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    [score : i64 (scratch-temporary-score 1234)]
    [kept : String (scratch-clone-message scratch 7)]
    [noise : String (scratch-clone-message scratch 99)]
    [expected-kept : String "kept:7"]
    [expected-noise : String "kept:99"]
    (begin
      (assert-i64-eq score 12 "scratch-only score")
      (assert-true (string-eq kept expected-kept) "clone-out kept result")
      (assert-true (string-eq noise expected-noise) "clone-out reused scratch")
      42)))