;; Fixed arrays of constant scalars are static data (#8369): every admitted
;; element type keeps its exact bits and width, and the storage stays an
;; ordinary writable array. Element writes, borrowed writes and whole-global
;; replacement work, and two tables with equal contents keep separate storage.
;; Several of these small arrays crash under the startup-initializer route
;; (#8488), which constant tables no longer take.
(import stdlib.math)

(define bytes8 : (Array u8 8)
  (array 0 1 127 128 200 254 255 7))
(define signed8 : (Array i8 4)
  (array -128 -1 0 127))
(define words : (Array u16 3)
  (array 0 65535 4660))
(define swords : (Array i16 3)
  (array -32768 -1 32767))
(define dwords : (Array u32 2)
  (array 4294967295 305419896))
(define sdwords : (Array i32 3)
  (array -2147483648 -1 2147483647))
(define qwords : (Array u64 2)
  (array 0xffffffffffffffff 0x0123456789abcdef))
(define sqwords : (Array i64 2)
  (array -9223372036854775807 9223372036854775807))
(define singles : (Array f32 3)
  (array 1.5 -0.0 3.4028235e38))
(define doubles : (Array f64 3)
  (array 0.1 -0.0 1e308))
(define flags : (Array bool 3)
  (array true false true))
(define letters : (Array char 3)
  (array 'a' 'z' '0'))
(define one : (Array i64 1)
  (array 42))
(define empty : (Array i64 0)
  (array))
(define wide : (Array u16 128)
  (array
    0
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
    19
    20
    21
    22
    23
    24
    25
    26
    27
    28
    29
    30
    31
    32
    33
    34
    35
    36
    37
    38
    39
    40
    41
    42
    43
    44
    45
    46
    47
    48
    49
    50
    51
    52
    53
    54
    55
    56
    57
    58
    59
    60
    61
    62
    63
    64
    65
    66
    67
    68
    69
    70
    71
    72
    73
    74
    75
    76
    77
    78
    79
    80
    81
    82
    83
    84
    85
    86
    87
    88
    89
    90
    91
    92
    93
    94
    95
    96
    97
    98
    99
    100
    101
    102
    103
    104
    105
    106
    107
    108
    109
    110
    111
    112
    113
    114
    115
    116
    117
    118
    119
    120
    121
    122
    123
    124
    125
    126
    127))
(define mutable : (Array i64 4)
  (array 1 2 3 4))
(define twin : (Array i64 4)
  (array 1 2 3 4))
(define replaced : (Array i64 2)
  (array 5 6))

(define (bump! [xs : (&mut xs (Array i64 4))]) : unit
  (set! (array-ref xs 3) (+ (array-ref xs 3) 100)))

(define (wide-sum) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i 128)
      (set! sum (+ sum (cast (array-ref wide i) : i64)))
      (set! i (+ i 1)))
    sum))

(define (check [ok : bool] [code : i64] [failed : i64]) : i64
  (if (or ok (!= failed 0))
    failed
    code))

(define (main) : i64
  (let
    [failed : i64 0]
    (set!
      failed
      (check
        (and
          (= (array-ref bytes8 0) 0)
          (= (array-ref bytes8 3) 128)
          (= (array-ref bytes8 6) 255)
          (= (array-ref bytes8 7) 7))
        1
        failed))
    (set!
      failed
      (check
        (and
          (= (array-ref signed8 0) -128)
          (= (array-ref signed8 1) -1)
          (= (array-ref signed8 3) 127))
        2
        failed))
    (set!
      failed
      (check
        (and
          (= (array-ref words 1) 65535)
          (= (array-ref words 2) 4660)
          (= (array-ref swords 0) -32768)
          (= (array-ref swords 1) -1)
          (= (array-ref swords 2) 32767))
        3
        failed))
    (set!
      failed
      (check
        (and
          (= (array-ref dwords 0) 4294967295)
          (= (array-ref dwords 1) 305419896)
          (= (array-ref sdwords 0) -2147483648)
          (= (array-ref sdwords 1) -1)
          (= (array-ref sdwords 2) 2147483647))
        4
        failed))
    (set!
      failed
      (check
        (and
          (= (array-ref qwords 0) 0xffffffffffffffff)
          (= (array-ref qwords 1) 0x0123456789abcdef)
          (= (array-ref sqwords 0) -9223372036854775807)
          (= (array-ref sqwords 1) 9223372036854775807))
        5
        failed))
    ;; Exact float bits, signed zero included.
    (set!
      failed
      (check
        (and
          (= (math.f32-to-bits (array-ref singles 0)) 0x3fc00000)
          (= (math.f32-to-bits (array-ref singles 1)) 0x80000000)
          (= (math.f32-to-bits (array-ref singles 2)) 0x7f7fffff)
          (= (math.f64-to-bits (array-ref doubles 0)) 0x3fb999999999999a)
          (= (math.f64-to-bits (array-ref doubles 1)) 0x8000000000000000)
          (= (math.f64-to-bits (array-ref doubles 2)) 0x7fe1ccf385ebc8a0))
        6
        failed))
    (set!
      failed
      (check
        (and
          (array-ref flags 0)
          (not (array-ref flags 1))
          (array-ref flags 2)
          (= (array-ref letters 0) 'a')
          (= (array-ref letters 1) 'z')
          (= (array-ref letters 2) '0'))
        7
        failed))
    (set!
      failed
      (check (and (= (array-ref one 0) 42) (= (wide-sum) 8128)) 8 failed))
    ;; Writes land in this global's own storage only, not in its twin's.
    (set! (array-ref mutable 0) 10)
    (bump! (&mut mutable))
    (set!
      failed
      (check
        (and
          (= (array-ref mutable 0) 10)
          (= (array-ref mutable 3) 104)
          (= (array-ref twin 0) 1)
          (= (array-ref twin 3) 4))
        9
        failed))
    (set! replaced (array 7 8))
    (set!
      failed
      (check
        (and (= (array-ref replaced 0) 7) (= (array-ref replaced 1) 8))
        10
        failed))
    (if (= failed 0)
      42
      failed)))