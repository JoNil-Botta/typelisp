;; Fixed arrays as SPMD operands (#8346): global and local fixed arrays, and
;; references to them, are gather sources, contiguous map sources and map
;; destinations, over empty, sub-gang, full-gang, multi-gang and partial-tail
;; ranges. Inactive tail lanes hold out-of-range gather indexes and must not
;; trap. Every result is checked against a scalar loop, and every backend mode
;; exits 42.
(define table-i64 : (Array i64 20)
  (array
    100
    103
    106
    109
    112
    115
    118
    121
    124
    127
    130
    133
    136
    139
    142
    145
    148
    151
    154
    157))
(define table-u64 : (Array u64 20)
  (array
    18446744073709551615
    1
    2
    3
    4
    5
    6
    7
    8
    9
    10
    11
    12
    13
    14
    15
    16
    17
    18
    9223372036854775808))
(define table-i32 : (Array i32 20)
  (array
    (cast -7 : i32)
    (cast 11 : i32)
    (cast 22 : i32)
    (cast 33 : i32)
    (cast 44 : i32)
    (cast 55 : i32)
    (cast 66 : i32)
    (cast 77 : i32)
    (cast 88 : i32)
    (cast 99 : i32)
    (cast 110 : i32)
    (cast 121 : i32)
    (cast 132 : i32)
    (cast 143 : i32)
    (cast 154 : i32)
    (cast 165 : i32)
    (cast 176 : i32)
    (cast 187 : i32)
    (cast 198 : i32)
    (cast 2147483647 : i32)))
(define table-f64 : (Array f64 20)
  (array
    0.5
    1.25
    -2.5
    3.75
    4.0
    5.5
    6.25
    7.0
    8.5
    9.75
    10.0
    11.5
    12.25
    13.0
    14.5
    15.75
    16.0
    17.5
    18.25
    19.0))

;; Out-of-range for every table, so a lane that reads one traps.
(define (fill-indexes [ix : (&mut ix (Array i64 20))] [n : i64]) : unit
  (let
    [k : i64 0]
    (while (< k 20)
      (set!
        (array-ref ix k)
        (if (< k n)
          (% (+ (* k 7) 3) 20)
          (+ 1000 k)))
      (set! k (+ k 1)))))

;; Global i64 and u64 sources, local index and destination arrays.
(define (check-global-i64 [n : i64]) : bool
  (let
    [ix : (Array i64 20) (make-array i64 20)]
    [got : (Array i64 20) (make-array i64 20)]
    [got-u : (Array u64 20) (make-array u64 20)]
    [k : i64 0]
    [ok : bool true]
    (fill-indexes (&mut ix) n)
    (foreach
      ([i : i64 0 n])
      (set! (array-ref got i) (array-ref table-i64 (array-ref ix i))))
    (foreach
      ([i : i64 0 n])
      (set! (array-ref got-u i) (array-ref table-u64 (array-ref ix i))))
    (while (< k n)
      (if (and
        (= (array-ref got k) (array-ref table-i64 (array-ref ix k)))
        (= (array-ref got-u k) (array-ref table-u64 (array-ref ix k))))
        unit
        (set! ok false))
      (set! k (+ k 1)))
    ok))

;; 32-bit lanes: a global i32 source, and a local u32 source derived from it.
(define (check-32 [n : i64]) : bool
  (let
    [ix : (Array i64 20) (make-array i64 20)]
    [local : (Array u32 20) (make-array u32 20)]
    [got : (Array i32 20) (make-array i32 20)]
    [got-u : (Array u32 20) (make-array u32 20)]
    [k : i64 0]
    [ok : bool true]
    (fill-indexes (&mut ix) n)
    (while (< k 20)
      (set! (array-ref local k) (cast (array-ref table-i32 k) : u32))
      (set! k (+ k 1)))
    (foreach
      ([i : i64 0 n])
      (set! (array-ref got i) (array-ref table-i32 (array-ref ix i))))
    (foreach
      ([i : i64 0 n])
      (set! (array-ref got-u i) (array-ref local (array-ref ix i))))
    (set! k 0)
    (while (< k n)
      (if (and
        (= (array-ref got k) (array-ref table-i32 (array-ref ix k)))
        (= (array-ref got-u k) (array-ref local (array-ref ix k))))
        unit
        (set! ok false))
      (set! k (+ k 1)))
    ok))

;; Float lanes through reference parameters: a shared source view and a
;; writable destination view whose stores stay visible after the loop.
(define (gather-f64
  [source : (& source (Array f64 20))]
  [ix : (& ix (Array i64 20))]
  [out : (&mut out (Array f64 20))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (array-ref source (array-ref ix i)))))

(define (gather-f32
  [source : (& source (Array f32 20))]
  [ix : (& ix (Array i64 20))]
  [out : (&mut out (Array f32 20))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (array-ref source (array-ref ix i)))))

(define (check-float [n : i64]) : bool
  (let
    [ix : (Array i64 20) (make-array i64 20)]
    [local-f32 : (Array f32 20) (make-array f32 20)]
    [got : (Array f64 20) (make-array f64 20)]
    [got-f32 : (Array f32 20) (make-array f32 20)]
    [k : i64 0]
    [ok : bool true]
    (fill-indexes (&mut ix) n)
    (while (< k 20)
      (set! (array-ref local-f32 k) (cast (array-ref table-f64 k) : f32))
      (set! k (+ k 1)))
    (gather-f64 (& table-f64) (& ix) (&mut got) n)
    (gather-f32 (& local-f32) (& ix) (&mut got-f32) n)
    (set! k 0)
    (while (< k n)
      (if (and
        (= (array-ref got k) (array-ref table-f64 (array-ref ix k)))
        (= (array-ref got-f32 k) (array-ref local-f32 (array-ref ix k))))
        unit
        (set! ok false))
      (set! k (+ k 1)))
    ok))

;; Contiguous map over fixed arrays, and the lane-offset gather whose offsets
;; are a fixed array. Equal offsets make the result independent of gang width.
(define (check-map [n : i64]) : bool
  (let
    [a : (Array i64 20) (make-array i64 20)]
    [sum : (Array i64 20) (make-array i64 20)]
    [shifted : (Array i64 20) (make-array i64 20)]
    [offsets : (Array i64 16) (array 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2)]
    [k : i64 0]
    [ok : bool true]
    (while (< k 20)
      (set! (array-ref a k) (- (* k k) 50))
      (set! k (+ k 1)))
    (foreach
      ([i : i64 0 n])
      (set! (array-ref sum i) (+ (array-ref a i) (array-ref table-i64 i))))
    (foreach
      ([i
          : i64
          0
          (if (> n 18)
            18
            n)])
      (set!
        (array-ref shifted i)
        (array-ref table-i64 (+ i (array-ref offsets (program-index))))))
    (set! k 0)
    (while (< k n)
      (if (= (array-ref sum k) (+ (array-ref a k) (array-ref table-i64 k)))
        unit
        (set! ok false))
      (if (and
        (< k 18)
        (not (= (array-ref shifted k) (array-ref table-i64 (+ k 2)))))
        (set! ok false)
        unit)
      (set! k (+ k 1)))
    ok))

(define (main) : i64
  (let
    [sizes : (Array i64 11) (array 0 1 3 4 7 8 9 15 16 17 20)]
    [k : i64 0]
    [failed : i64 0]
    (while (< k 11)
      (let
        [n : i64 (array-ref sizes k)]
        (if (check-global-i64 n)
          unit
          (set! failed 1))
        (if (check-32 n)
          unit
          (set! failed 2))
        (if (check-float n)
          unit
          (set! failed 3))
        (if (check-map n)
          unit
          (set! failed 4))
        (set! k (+ k 1))))
    (if (= failed 0)
      42
      failed)))