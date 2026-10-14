;; A by-value local narrower than a word passed as `(&mut local)` is copied into
;; a slot of its own size for the call and read back after it. The read-back
;; must be just as narrow: the rest of the word holds whatever an earlier call
;; left on the stack. A word load there made `added` read as true forever at
;; opt2, so `rounds` ran to its cap. `score` covers the other referent shapes:
;; a byte, a float, one- and two-word structs, a memory struct and an enum.
(defstruct One
  (a u8)
  (b bool))

(defstruct Two
  (a i64)
  (b i64))

(defstruct Three
  (a i64)
  (b i64)
  (c i64))

(defenum Pick
  (Left i64)
  (Right))

(define (dirty [seed : i64]) : i64
  (let
    [cells : (Array i64 16)
      (array
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed
        seed)]
    [total : i64 0]
    [i : i64 0]
    (while (< i 16)
      (set! total (+ total (array-ref cells i)))
      (set! i (+ i 1)))
    total))

(define (step! [counter : (&mut c i64)] [limit : i64] [added : (&mut a bool)]) : unit
  (when
    (< (deref counter) limit)
    (set! (deref counter) (+ (deref counter) 1))
    (set! (deref added) true)))

(define (rounds [limit : i64]) : i64
  (let
    [counter : i64 0]
    [added : bool true]
    [count : i64 0]
    (while (and added (< count 100))
      (set! added false)
      (step! (&mut counter) limit (&mut added))
      (set! count (+ count 1)))
    count))

(define (bump! [value : (&mut v i32)]) : unit
  (set! (deref value) (+ (deref value) 1)))

(define (narrow-i32) : i64
  (let
    [value : i32 (cast 7 : i32)]
    (bump! (&mut value))
    (cast value : i64)))

(define (bump-u8! [x : (&mut x u8)]) : unit
  (set! (deref x) (+ (deref x) (cast 1 : u8))))

(define (bump-f64! [x : (&mut x f64)]) : unit
  (set! (deref x) (+ (deref x) 1.5)))

(define (bump-one! [x : (&mut x One)]) : unit
  (set! x.a (+ x.a (cast 2 : u8)))
  (set! x.b false))

(define (bump-two! [x : (&mut x Two)]) : unit
  (set! x.b (+ x.b 3)))

(define (bump-three! [x : (&mut x Three)]) : unit
  (set! x.c (+ x.c 4)))

(define (bump-pick! [x : (&mut x Pick)]) : unit
  (set! (deref x) (Pick.Left 5)))

;; 2 + 1 + 3 + 0 + 4 + 5 + 5 = 20.
(define (score) : i64
  (let
    [u : u8 (cast 1 : u8)]
    [f : f64 0.5]
    [one : One (One (cast 1 : u8) true)]
    [two : Two (Two 1 1)]
    [three : Three (Three 1 1 1)]
    [pick : Pick Pick.Right]
    (bump-u8! (&mut u))
    (bump-f64! (&mut f))
    (bump-one! (&mut one))
    (bump-two! (&mut two))
    (bump-three! (&mut three))
    (bump-pick! (&mut pick))
    (+
      (cast u : i64)
      (if (= f 2.0)
        1
        100)
      (cast one.a : i64)
      (if one.b
        100
        0)
      two.b
      three.c
      (match pick
        [(Pick.Left v) v]
        [(Pick.Right) 100]))))

(define (main) : i64
  (let
    [noise : i64 (dirty -1)]
    ;; 4 + 1 rounds, 8 from the i32, 20 from `score`, 9 when the noise was
    ;; written.
    (+
      (rounds 3)
      (rounds 0)
      (narrow-i32)
      (score)
      (if (< noise 0)
        9
        0))))