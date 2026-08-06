;; vector_macro_i64.tl - runnable scalar coverage for stdlib `(vector.vector T)`.
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector i64) as ivec)
(import (vector.vector String) as svec)

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
          (ivec.push (&mut v) (* i 3))
          (set! i (+ i 1))))
      v)))

(define (vector-macro-slice-sum [view : (& source (Slice i64))]) : i64
  (let
    [index : i64 0]
    [sum : i64 0]
    (begin
      (while (< index (array-length view))
        (begin
          (set! sum (+ sum (array-ref view index)))
          (set! index (+ index 1))))
      sum)))

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
      (ivec.set (&mut v) 2 99)
      (test.assert-i64-eq
        (ivec.get (& v) 2 -1)
        99
        "i64 vector macro set in place")
      (test.assert-i64-eq (ivec.len (& v)) 9 "i64 vector macro set keeps len"))))

(test
  vector-macro-i64-derived-helpers
  (let
    [v : ivec.Vec (ivec.with-capacity 5)]
    (begin
      (ivec.push (&mut v) 4)
      (ivec.push (&mut v) 5)
      (ivec.push (&mut v) 6)
      (ivec.push (&mut v) 4)
      (ivec.push (&mut v) 5)
      (ivec.reverse! (&mut v))
      (let
        [mapped : ivec.Vec (ivec.map (& v) vector-macro-i64-triple)]
        (begin
          (test.assert-i64-eq (ivec.len (& v)) 5 "push builds vector length")
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
          (test.assert-i64-eq (ivec.len (& mapped)) 5 "map preserves length")
          (test.assert-i64-eq
            (ivec.get (& mapped) 0 -1)
            15
            "map returns transformed first")
          (test.assert-true
            (ivec.contains? (& mapped) 18)
            "contains? finds scalar")
          (match (ivec.pop (&mut v))
            [(ivec.Pop.Ok value)
              (begin
                (test.assert-i64-eq value 4 "pop returns last value")
                (test.assert-i64-eq (ivec.len (& v)) 4 "pop shrinks in place"))]
            [ivec.Pop.Empty
              (test.assert-true false "pop should return a value")]))))))

(test
  vector-macro-string-alias
  (let
    [words : svec.Vec (svec.new)]
    [expected : String "bee"]
    (begin
      (svec.push (&mut words) "alpha")
      (svec.push (&mut words) "beta")
      (svec.set (&mut words) 1 "bee")
      (test.assert-i64-eq (svec.len (& words)) 2 "aliased string vector length")
      (let
        [view : (& words (Slice String)) (svec.view (& words))]
        (test.assert-i64-eq
          (array-length view)
          2
          "string native slice preserves String element"))
      (test.assert-true
        (svec.contains? (& words) "bee")
        "aliased string contains")
      (match (svec.pop (&mut words))
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

(test
  vector-macro-native-slice-views
  (let
    [items : ivec.Vec (ivec.with-capacity 8)]
    (begin
      (ivec.push (&mut items) 5)
      (ivec.push (&mut items) 6)
      (ivec.push (&mut items) 7)
      (let
        [full : (& items (Slice i64)) (ivec.view (& items))]
        [middle : (& items (Slice i64)) (slice-view full 1 2)]
        [copy : ivec.Vec (ivec.from-slice middle)]
        (begin
          (test.assert-i64-eq (array-length full) 3 "native full view len")
          (test.assert-i64-eq (array-length middle) 2 "native subview len")
          (test.assert-i64-eq (array-ref middle 0) 6 "native subview first")
          (test.assert-i64-eq
            (vector-macro-slice-sum middle)
            13
            "native slice traversal")
          (test.assert-i64-eq (ivec.len (& copy)) 2 "native slice copy len")
          (test.assert-i64-eq
            (ivec.get (& copy) 1 -1)
            7
            "native slice copy value")))
      (let
        [view : (&mut items (Slice i64)) (ivec.view-mut (&mut items))]
        (array-set! view 1 44))
      (test.assert-i64-eq
        (ivec.get (& items) 1 -1)
        44
        "native mutable view updates vector"))))