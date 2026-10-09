;; #8776: with-escape and with-scratch check their body under a region scoped
;; to the form. Allocations that stay in the body, values cloned out as the
;; form's result, and scratch forms nested with with-arena keep working.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct Label
  (name String)
  (weight i64))

(defenum Parsed
  (Ok String)
  (Err i64))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok (string.int->string n))
    (Parsed.Err n)))

;; Takes a body allocation by value, as ordinary helpers do.
(define (decorate [text : String]) : String
  (string.append "<" (string.append (& text) ">")))

(define (scratch-string [n : i64]) : String
  (with-scratch
    (let
      [digits : String (string.int->string n)]
      (decorate digits))))

(define (escape-vec [scratch : arena.Arena] [count : i64]) : ivec.Vec
  (with-escape
    scratch
    (let
      [v : ivec.Vec (ivec.new)]
      [i : i64 0]
      (while (< i count)
        (ivec.push-ref! (&mut v) (* i i))
        (set! i (+ i 1)))
      v)))

(define (scratch-label [n : i64]) : Label
  (with-scratch (Label (decorate (string.int->string n)) n)))

;; A try whose error payload is a scalar, with the Ok value used in the body.
(define (scratch-try-length [n : i64]) : Parsed
  (let
    [len : i64
      (with-scratch
        (let
          [text : String (try (parse n))]
          (string.string-length (& text))))]
    (Parsed.Ok (string.int->string len))))

(define (arena-in-escape [scratch : arena.Arena]) : String
  (with-escape
    scratch
    (let
      [kept : String (string.int->string 77)]
      (with-arena inner (string.string-length (string.int->string 123456)))
      kept)))

(define (escape-in-arena [scratch : arena.Arena]) : i64
  (with-arena
    phase
    (let
      [copied : String (with-escape scratch (decorate (string.int->string 5)))]
      (string.string-length (& copied)))))

;; Overwrite freed scratch storage so a dangling result would read garbage.
(define (clobber) : i64
  (with-scratch (string.string-length (string.int->string 987654321987654321))))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [s : String (scratch-string 1234567)]
    [v : ivec.Vec (escape-vec scratch 40)]
    [label : Label (scratch-label 31)]
    [tried : Parsed (scratch-try-length 4242)]
    [failed : Parsed (scratch-try-length -3)]
    [kept : String (arena-in-escape scratch)]
    [inner : i64 (escape-in-arena scratch)]
    (clobber)
    (with-escape scratch (clobber))
    (if (and
      (string.eq (& s) "<1234567>")
      (= (ivec.get (& v) 39 -1) 1521)
      (string.eq (& label.name) "<31>")
      (= label.weight 31)
      (match tried
        [(Parsed.Ok text) (string.eq (& text) "4")]
        [(Parsed.Err _) false])
      (match failed
        [(Parsed.Ok _) false]
        [(Parsed.Err n) (= n -3)])
      (string.eq (& kept) "77")
      (= inner 3))
      42
      1)))