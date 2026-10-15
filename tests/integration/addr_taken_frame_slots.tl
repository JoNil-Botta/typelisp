;; An address keeps local storage live after its last direct IR mention.
(define (straight [seed : i64]) : i64
  (let
    [value : i64 seed]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [rounds : i64 1]
    [loaded : i64
      (unsafe
        (ptr-read p))]
    (+ (* loaded 5) (+ rounds 6))))

(define (loop-carried [seed : i64]) : i64
  (let
    [value : i64 seed]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [copy : (MutPtr i64) p]
    [rounds : i64 1]
    [sum : i64 0]
    [count : i64 0]
    (while (< count 3)
      (let
        [loaded : i64
          (unsafe
            (ptr-read copy))]
        (+= sum loaded)
        (unsafe
          (ptr-write! p (+ loaded 1))))
      (+= count 1))
    (+
      (+
        sum
        (unsafe
          (ptr-read copy)))
      (+ rounds 7))))

(define (two-addresses [seed : i64]) : i64
  (let
    [first : i64 seed]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    [second : i64 (+ seed 4)]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of second))]
    [noise : i64 24]
    (+
      (+
        (unsafe
          (ptr-read p))
        (unsafe
          (ptr-read q)))
      noise)))

(define (byte-slot [seed : u8]) : i64
  (let
    [value : u8 seed]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of value))]
    [noise : u8 (cast 1 : u8)]
    (+
      (cast
        (unsafe
          (ptr-read p))
        : i64)
      (cast noise : i64))))

(define (parameter-slot [value : i64]) : i64
  (let
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [noise : i64 1]
    (+
      (*
        (unsafe
          (ptr-read p))
        5)
      (+ noise 6))))

(define (main) : i64
  (cond
    [(not (= (straight 7) 42)) 1]
    [(not (= (loop-carried 7) 42)) 2]
    [(not (= (two-addresses 7) 42)) 3]
    [(not (= (byte-slot (cast 41 : u8)) 42)) 4]
    [(not (= (parameter-slot 7) 42)) 5]
    [else 42]))