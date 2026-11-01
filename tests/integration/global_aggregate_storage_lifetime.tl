;; An inline aggregate global keeps its static home (SPEC 5.10): replacing it in
;; a temporary arena copies into that home and allocates nothing.
(import stdlib.arena)
(import stdlib.profile)
(import stdlib.test)

(cfg
  compiler-arena-debug
  (unsafe
    (extern (debug-layout [owner : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install"))))

(defstruct Record
  (a i64)
  (b i64)
  (c i64))

(defstruct Owner
  (handle (Box i64))
  (first i64)
  (last i64))

(define owner : Owner
  (Owner (box 1) 2 3))

(defstruct Small
  (value i64))

(define scalar : i64
  0)
(define small : Small
  (Small 0))

(defenum Choice
  (Value i64 i64 i64 i64)
  (Empty))

(define values : (Array i64 2)
  (array 10 20))
(define triple : (Tuple i64 i64 i64)
  (tuple 1 2 3))
(define record : Record
  (Record 1 2 3))
(define choice : Choice
  (Choice.Value 1 2 3 4))
(define large : (Array i64 65)
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
    64))

(define (install [seed : i64]) : unit
  (set! values (array seed (+ seed 1)))
  (set! triple (tuple seed (+ seed 1) (+ seed 2)))
  (set! record (Record seed (+ seed 1) (+ seed 2)))
  (set! choice (Choice.Value seed (+ seed 1) (+ seed 2) (+ seed 3)))
  (set!
    large
    (array
      seed
      (+ seed 1)
      (+ seed 2)
      (+ seed 3)
      (+ seed 4)
      (+ seed 5)
      (+ seed 6)
      (+ seed 7)
      (+ seed 8)
      (+ seed 9)
      (+ seed 10)
      (+ seed 11)
      (+ seed 12)
      (+ seed 13)
      (+ seed 14)
      (+ seed 15)
      (+ seed 16)
      (+ seed 17)
      (+ seed 18)
      (+ seed 19)
      (+ seed 20)
      (+ seed 21)
      (+ seed 22)
      (+ seed 23)
      (+ seed 24)
      (+ seed 25)
      (+ seed 26)
      (+ seed 27)
      (+ seed 28)
      (+ seed 29)
      (+ seed 30)
      (+ seed 31)
      (+ seed 32)
      (+ seed 33)
      (+ seed 34)
      (+ seed 35)
      (+ seed 36)
      (+ seed 37)
      (+ seed 38)
      (+ seed 39)
      (+ seed 40)
      (+ seed 41)
      (+ seed 42)
      (+ seed 43)
      (+ seed 44)
      (+ seed 45)
      (+ seed 46)
      (+ seed 47)
      (+ seed 48)
      (+ seed 49)
      (+ seed 50)
      (+ seed 51)
      (+ seed 52)
      (+ seed 53)
      (+ seed 54)
      (+ seed 55)
      (+ seed 56)
      (+ seed 57)
      (+ seed 58)
      (+ seed 59)
      (+ seed 60)
      (+ seed 61)
      (+ seed 62)
      (+ seed 63)
      (+ seed 64))))

(define (check-values-with-first [first : i64] [seed : i64]) : unit
  (test.assert-i64-eq (array-ref values 0) first "fixed-array first element")
  (test.assert-i64-eq
    (array-ref values 1)
    (+ seed 1)
    "fixed-array last element")
  (test.assert-i64-eq (tuple-ref triple 2) (+ seed 2) "tuple storage")
  (test.assert-i64-eq record.c (+ seed 2) "struct storage")
  (test.assert-true
    (match choice
      [(Choice.Value a b c d)
        (and (= a seed) (= b (+ seed 1)) (= c (+ seed 2)) (= d (+ seed 3)))]
      [_ false])
    "payload enum storage")
  (test.assert-i64-eq (array-ref large 0) seed "large first element")
  (test.assert-i64-eq (array-ref large 64) (+ seed 64) "large last element"))

(define (check-values [seed : i64]) : unit
  (check-values-with-first seed seed))

(define (install-in-scope [seed : i64]) : unit
  (let
    [before : i64 (arena.tl_arena_current)]
    (install seed)
    (test.assert-i64-eq
      (arena.tl_arena_current)
      before
      "current arena restored")))

(define (replace-recursively [depth : i64] [seed : i64]) : i64
  (with-scratch (install-in-scope (+ seed depth)))
  (if (> depth 0)
    (begin
      ;; The element place is the global's own home: the replacement inside
      ;; the value writes it, and the store then lands there.
      (set!
        (array-ref values 0)
        (if (= (bit-and depth 1) 0)
          (replace-recursively (- depth 1) seed)
          (replace-transitively (- depth 1) seed)))
      (check-values-with-first 7 seed))
    (check-values seed))
  7)

(define (replace-transitively [depth : i64] [seed : i64]) : i64
  (replace-recursively depth seed))

(define (main) : i64
  (cfg
    compiler-arena-debug
    (unsafe
      (debug-layout 0)))
  (let
    [replacement : Small (Small 42)]
    (with-scratch
      (let
        [before : i64 (profile.alloc-total)]
        (set! scalar 41)
        (set! small replacement)
        (test.assert-i64-eq
          (profile.alloc-total)
          before
          "register-class global stores do not allocate"))))
  (test.assert-i64-eq scalar 41 "scalar global value")
  (test.assert-i64-eq small.value 42 "register-class global value")
  (let
    [i : i64 0]
    (while (< i 32)
      (with-scratch (install-in-scope i))
      (check-values i)
      (+= i 1)))
  (with-scratch (with-scratch (install-in-scope 41)) (check-values 41))
  (check-values 41)
  (let
    [scratch : arena.Arena (arena.make)]
    (with-escape scratch (install-in-scope 42) 0)
    (arena.destroy-safe! scratch))
  (check-values 42)
  (with-arena phase (install-in-scope 43))
  (check-values 43)
  (let
    [before : i64 (profile.alloc-total)]
    (with-scratch (install-in-scope 44))
    (test.assert-i64-eq
      (profile.alloc-total)
      before
      "aggregate global stores copy into their home"))
  (check-values 44)
  (set! (array-ref values 0) (replace-recursively 3 73))
  (check-values-with-first 7 73)
  (let
    [local : (Array i64 2) (array 10 20)]
    (set! (array-ref local 0) (replace-recursively 2 83))
    (test.assert-i64-eq
      (array-ref local 0)
      7
      "local receiver after global replacement")
    (test.assert-i64-eq
      (array-ref local 1)
      20
      "local sibling after global replacement")
    (check-values-with-first 7 83))
  (let
    [replacement : Owner (Owner (box 42) 7 8)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of replacement.handle) : (Ptr u64))))]
    (with-scratch (set! owner replacement))
    (test.assert-i64-eq
      (deref owner.handle)
      42
      "owning payload survives shallow transfer")
    (test.assert-true
      (=
        (unsafe
          (ptr-read (ptr-cast (ptr-addr-of owner.handle) : (Ptr u64))))
        address)
      "implicit storage copy retains Box identity"))
  42)