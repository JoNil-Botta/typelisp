;; vector_macro_i64.tl - runnable scalar coverage for stdlib `(vector T)`.
(import stdlib.test)
(import stdlib.vector)
(import (vector i64) as ivec)
(import (vector String) as svec)

(define (vector-macro-i64-triple [x : i64]) : i64
  (* x 3))

(define (vector-macro-i64-add [a : i64] [b : i64]) : i64
  (+ a b))

(define (vector-macro-i64-mut-len [v : (&mut v ivec.Vec)]) : i64
  (ivec.len-mut v))

(define (vector-macro-i64-fill [n : i64]) : ivec.Vec
  (let
    [v : ivec.Vec (ivec.new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (ivec.push! v (* i 3))
          (set! i (+ i 1))))
      v)))

(test
  vector-macro-i64-growth
  (let
    [v : ivec.Vec (vector-macro-i64-fill 9)]
    (begin
      (test.assert-i64-eq (ivec.len (& v)) 9 "i64 vector macro length")
      (test.assert-i64-eq
        (vector-macro-i64-mut-len (&mut v))
        9
        "i64 vector macro mutable length")
      (test.assert-i64-eq
        (ivec.capacity (& v))
        16
        "i64 vector macro doubled capacity")
      (test.assert-i64-eq
        (ivec.get (& v) 0 -1)
        0
        "i64 vector macro keeps first element")
      (test.assert-i64-eq
        (ivec.get (& v) 7 -1)
        21
        "i64 vector macro keeps grown element")
      (test.assert-i64-eq
        (ivec.get (& v) 9 -1)
        -1
        "i64 vector macro get at len fallback")
      (test.assert-i64-eq
        (ivec.get (& v) -1 -1)
        -1
        "i64 vector macro negative fallback")
      (ivec.set! v 2 99)
      (test.assert-i64-eq
        (ivec.get (& v) 2 -1)
        99
        "i64 vector macro set in place")
      (test.assert-i64-eq (ivec.len (& v)) 9 "i64 vector macro set keeps len"))))

(test
  vector-macro-i64-derived-helpers
  (let
    [src : (Array i64) (make-array i64 3)]
    (begin
      (array-set! src 0 4)
      (array-set! src 1 5)
      (array-set! src 2 6)
      (let
        [v : ivec.Vec (ivec.from-array (& src) 3)]
        (begin
          (ivec.extend! v (& src) 2)
          (ivec.reverse! v)
          (test.assert-i64-eq (ivec.len (& v)) 5 "extend mutates vector length")
          (test.assert-i64-eq
            (ivec.get (& v) 0 -1)
            5
            "reverse mutates first slot")
          (test.assert-i64-eq
            (ivec.get (& v) 4 -1)
            4
            "reverse mutates last slot")
          (test.assert-i64-eq
            (ivec.fold (& v) 0 vector-macro-i64-add)
            24
            "fold sees all live values")
          (let
            [mapped : ivec.Vec (ivec.map (& v) vector-macro-i64-triple)]
            [snapshot : (Array i64) (ivec.to-array (& mapped))]
            (begin
              (test.assert-i64-eq
                (ivec.len (& mapped))
                5
                "map preserves length")
              (test.assert-i64-eq
                (array-ref snapshot 0)
                15
                "to-array snapshots mapped first")
              (test.assert-true
                (ivec.contains? (& mapped) 18)
                "contains? finds scalar")
              (match (ivec.pop! v)
                [(ivec.Pop.Ok value)
                  (begin
                    (test.assert-i64-eq value 4 "pop returns last value")
                    (test.assert-i64-eq
                      (ivec.len (& v))
                      4
                      "pop shrinks in place"))]
                [ivec.Pop.Empty
                  (test.assert-true false "pop should return a value")]))))))))

(test
  vector-macro-string-alias
  (let
    [words : svec.Vec (svec.new)]
    [expected : String "bee"]
    (begin
      (svec.push! words "alpha")
      (svec.push! words "beta")
      (svec.set! words 1 "bee")
      (test.assert-i64-eq (svec.len (& words)) 2 "aliased string vector length")
      (test.assert-true
        (svec.contains? (& words) "bee")
        "aliased string contains")
      (match (svec.pop! words)
        [(svec.Pop.Ok value)
          (begin
            (test.assert-string-eq
              (& value)
              (& expected)
              "aliased string pop value")
            (test.assert-i64-eq
              (svec.len (& words))
              1
              "aliased string pop shrinks"))]
        [svec.Pop.Empty
          (test.assert-true false "aliased string pop should return a value")]))))