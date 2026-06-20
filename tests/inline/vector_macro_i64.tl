;; vector_macro_i64.tl - runnable scalar coverage for stdlib `(vector T)`.
(import "stdlib/test.tl")
(import "stdlib/vector.tl")
(import (vector i64))
(import (vector String) as svec)

(define (vector-macro-i64-triple [x : i64]) : i64
  (* x 3))

(define (vector-macro-i64-add [a : i64] [b : i64]) : i64
  (+ a b))

(define (vector-macro-i64-mut-len [v : (&mut v Vec)]) : i64
  (len-mut v))

(define (vector-macro-i64-fill [n : i64]) : Vec
  (let
    [v : Vec (new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (push (&mut v) (* i 3))
          (set! i (+ i 1))))
      v)))

(test
  vector-macro-i64-growth
  (let
    [v : Vec (vector-macro-i64-fill 9)]
    (begin
      (assert-i64-eq (len (& v)) 9 "i64 vector macro length")
      (assert-i64-eq
        (vector-macro-i64-mut-len (&mut v))
        9
        "i64 vector macro mutable length")
      (assert-i64-eq (capacity (& v)) 16 "i64 vector macro doubled capacity")
      (assert-i64-eq (get (& v) 0 -1) 0 "i64 vector macro keeps first element")
      (assert-i64-eq (get (& v) 7 -1) 21 "i64 vector macro keeps grown element")
      (assert-i64-eq (get (& v) 9 -1) -1 "i64 vector macro get at len fallback")
      (assert-i64-eq (get (& v) -1 -1) -1 "i64 vector macro negative fallback")
      (set (&mut v) 2 99)
      (assert-i64-eq (get (& v) 2 -1) 99 "i64 vector macro set in place")
      (assert-i64-eq (len (& v)) 9 "i64 vector macro set keeps len"))))

(test
  vector-macro-i64-derived-helpers
  (let
    [src : (Array i64) (make-array i64 3)]
    (begin
      (array-set! src 0 4)
      (array-set! src 1 5)
      (array-set! src 2 6)
      (let
        [v : Vec (from-array (& src) 3)]
        (begin
          (extend (&mut v) (& src) 2)
          (reverse! (&mut v))
          (assert-i64-eq (len (& v)) 5 "extend mutates vector length")
          (assert-i64-eq (get (& v) 0 -1) 5 "reverse mutates first slot")
          (assert-i64-eq (get (& v) 4 -1) 4 "reverse mutates last slot")
          (assert-i64-eq
            (fold (& v) 0 vector-macro-i64-add)
            24
            "fold sees all live values")
          (let
            [mapped : Vec (map (& v) vector-macro-i64-triple)]
            [snapshot : (Array i64) (to-array (& mapped))]
            (begin
              (assert-i64-eq (len (& mapped)) 5 "map preserves length")
              (assert-i64-eq
                (array-ref snapshot 0)
                15
                "to-array snapshots mapped first")
              (assert-true (contains? (& mapped) 18) "contains? finds scalar")
              (match (pop (&mut v))
                [(Pop.Ok value)
                  (begin
                    (assert-i64-eq value 4 "pop returns last value")
                    (assert-i64-eq (len (& v)) 4 "pop shrinks in place"))]
                [Pop.Empty (assert-true false "pop should return a value")]))))))))

(test
  vector-macro-string-alias
  (let
    [words : svec.Vec (svec.new)]
    [expected : String "bee"]
    (begin
      (svec.push (&mut words) "alpha")
      (svec.push (&mut words) "beta")
      (svec.set (&mut words) 1 "bee")
      (assert-i64-eq (svec.len (& words)) 2 "aliased string vector length")
      (assert-true (svec.contains? (& words) "bee") "aliased string contains")
      (match (svec.pop (&mut words))
        [(svec.Pop.Ok value)
          (begin
            (assert-string-eq (& value) (& expected) "aliased string pop value")
            (assert-i64-eq (svec.len (& words)) 1 "aliased string pop shrinks"))]
        [svec.Pop.Empty
          (assert-true false "aliased string pop should return a value")]))))