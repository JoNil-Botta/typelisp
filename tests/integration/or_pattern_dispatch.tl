;; How or-pattern arms dispatch: alternatives that bind alike share one bind
;; block (or the body block itself), others bind on their own, and or-pattern
;; arms among a match's last four tag tests keep the total enum switch. The
;; arm bodies are large enough to stay shared rather than copied per
;; alternative.
(defenum Op
  (Add i64 i64)
  (Neg i64)
  (Sub i64 i64)
  (Inc i64)
  (Flag bool i64)
  (Nop)
  (Halt)
  (Dup i64)
  (Swap i64 i64)
  (Push i64))

(define (h [x : i64] [k : i64]) : i64
  (+ (* x 10) k))

;; 160x + 136.
(define (spread [x : i64]) : i64
  (+
    (h x 1)
    (h x 2)
    (h x 3)
    (h x 4)
    (h x 5)
    (h x 6)
    (h x 7)
    (h x 8)
    (h x 9)
    (h x 10)
    (h x 11)
    (h x 12)
    (h x 13)
    (h x 14)
    (h x 15)
    (h x 16)))

;; Every alternative of the first arm binds `x` from the same payload slot, so
;; it binds in the body block; the final arm's alternatives bind from
;; different slots.
(define (owned-first [op : Op]) : i64
  (match op
    [(or (Add x _) (Sub x _) (Neg x) (Inc x) (Dup x))
      (+
        (h x 1)
        (h x 2)
        (h x 3)
        (h x 4)
        (h x 5)
        (h x 6)
        (h x 7)
        (h x 8)
        (h x 9)
        (h x 10)
        (h x 11)
        (h x 12)
        (h x 13)
        (h x 14)
        (h x 15)
        (h x 16))]
    [(Flag _ y) (+ y 1)]
    [(or Nop Halt) 7]
    [(or (Swap _ z) (Push z))
      (-
        0
        (+
          (h z 1)
          (h z 2)
          (h z 3)
          (h z 4)
          (h z 5)
          (h z 6)
          (h z 7)
          (h z 8)
          (h z 9)
          (h z 10)
          (h z 11)
          (h z 12)
          (h z 13)
          (h z 14)
          (h z 15)
          (h z 16)))]))

;; Two groups: `x` at the first payload word (Add, Sub, Dup) and at the
;; second (Swap, Flag), through a borrow. Each group lowers as an or-arm of
;; its own.
(define (borrowed-groups [op : (& o Op)]) : i64
  (match op
    [(or (Add x _) (Sub x _) (Dup x) (Swap _ x) (Flag _ x))
      (+
        (h x 1)
        (h x 2)
        (h x 3)
        (h x 4)
        (h x 5)
        (h x 6)
        (h x 7)
        (h x 8)
        (h x 9)
        (h x 10)
        (h x 11)
        (h x 12)
        (h x 13)
        (h x 14)
        (h x 15)
        (h x 16))]
    [(Neg n) (- 0 n)]
    [(or Nop Halt (Inc _) (Push _)) 0]))

;; Refutable alternatives bind on their own and fall through to the next
;; alternative's test; Sub and Dup share a bind block.
(define (mixed [op : Op]) : i64
  (match op
    [(or (Add x 0) (Sub x _) (Dup x) (Swap x 1))
      (+
        (h x 1)
        (h x 2)
        (h x 3)
        (h x 4)
        (h x 5)
        (h x 6)
        (h x 7)
        (h x 8)
        (h x 9)
        (h x 10)
        (h x 11)
        (h x 12)
        (h x 13)
        (h x 14)
        (h x 15)
        (h x 16))]
    [(Add a b) (+ a b)]
    [(Swap a b) (* a b)]
    [_ -1]))

;; Literal alternatives bind nothing: each test jumps to the body.
(define (odd-digit [n : i64]) : i64
  (match n
    [(or 1 3 5 7 9)
      (+
        (h n 1)
        (h n 2)
        (h n 3)
        (h n 4)
        (h n 5)
        (h n 6)
        (h n 7)
        (h n 8)
        (h n 9)
        (h n 10)
        (h n 11)
        (h n 12)
        (h n 13)
        (h n 14)
        (h n 15)
        (h n 16))]
    [(or 0 2 4 6 8) 0]
    [_ -1]))

;; A final arm of six alternatives holds the match's last four tag tests.
(define (final-group [op : Op]) : i64
  (match op
    [(Flag b _)
      (if b
        1
        0)]
    [Nop 2]
    [Halt 3]
    [(Swap a b) (+ a b)]
    [(or (Add x _) (Sub x _) (Neg x) (Inc x) (Dup x) (Push x))
      (+
        (h x 1)
        (h x 2)
        (h x 3)
        (h x 4)
        (h x 5)
        (h x 6)
        (h x 7)
        (h x 8)
        (h x 9)
        (h x 10)
        (h x 11)
        (h x 12)
        (h x 13)
        (h x 14)
        (h x 15)
        (h x 16))]))

(define (main) : i64
  (let
    [add : Op (Add 1 2)]
    [swap : Op (Swap 1 2)]
    [flag : Op (Flag false 3)]
    [dup : Op (Dup 0)]
    [neg : Op (Neg 4)]
    [inc : Op (Inc 1)]
    [halt : Op Halt]
    (begin
      (unless (= (owned-first (Add 2 9)) (spread 2)) (return 1))
      (unless (= (owned-first (Sub 3 0)) (spread 3)) (return 2))
      (unless (= (owned-first (Neg 1)) (spread 1)) (return 3))
      (unless (= (owned-first (Inc 0)) (spread 0)) (return 4))
      (unless (= (owned-first (Dup 5)) (spread 5)) (return 5))
      (unless (= (owned-first (Flag true 4)) 5) (return 6))
      (unless (= (owned-first Nop) 7) (return 7))
      (unless (= (owned-first Halt) 7) (return 8))
      (unless (= (owned-first (Swap 1 2)) (- 0 (spread 2))) (return 9))
      (unless (= (owned-first (Push 3)) (- 0 (spread 3))) (return 10))
      (unless (= (borrowed-groups (& add)) (spread 1)) (return 11))
      (unless (= (borrowed-groups (& swap)) (spread 2)) (return 12))
      (unless (= (borrowed-groups (& flag)) (spread 3)) (return 13))
      (unless (= (borrowed-groups (& dup)) (spread 0)) (return 14))
      (unless (= (borrowed-groups (& neg)) -4) (return 15))
      (unless (= (borrowed-groups (& inc)) 0) (return 16))
      (unless (= (borrowed-groups (& halt)) 0) (return 17))
      (unless (= (mixed (Add 2 0)) (spread 2)) (return 18))
      (unless (= (mixed (Add 2 5)) 7) (return 19))
      (unless (= (mixed (Sub 1 9)) (spread 1)) (return 20))
      (unless (= (mixed (Dup 3)) (spread 3)) (return 21))
      (unless (= (mixed (Swap 0 1)) (spread 0)) (return 22))
      (unless (= (mixed (Swap 2 3)) 6) (return 23))
      (unless (= (mixed Nop) -1) (return 24))
      (unless (= (odd-digit 3) (spread 3)) (return 25))
      (unless (= (odd-digit 4) 0) (return 26))
      (unless (= (odd-digit 12) -1) (return 27))
      (unless (= (final-group (Push 1)) (spread 1)) (return 28))
      (unless (= (final-group (Neg 2)) (spread 2)) (return 29))
      (unless (= (final-group (Flag true 0)) 1) (return 30))
      (unless (= (final-group Nop) 2) (return 31))
      (unless (= (final-group (Swap 2 3)) 5) (return 32))
      (unless (= (final-group (Inc 4)) (spread 4)) (return 33))
      42)))