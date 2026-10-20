;; Direct definitions of an address-taken local are writes to its storage.
;; 1: issue reproducer, straight line.
(define (load-after-set) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (begin
      (set! value 5)
      (+
        a
        (unsafe
          (ptr-read p))))))

;; 2: the set! is in a branch, the second load after the join.
(define (load-after-branch-set [c : i64]) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (begin
      (if (> c 0)
        (set! value 5)
        (set! value 6))
      (+
        a
        (unsafe
          (ptr-read p))))))

;; 3: loop: each iteration sets the local, then reads it through p.
(define (loop-read-through [n : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! value i)
          (set!
            sum
            (+
              sum
              (unsafe
                (ptr-read p))))
          (set! i (+ i 1))))
      sum)))

;; 4: a load taken before the set! keeps the old value (load sinking).
(define (load-before-set-kept [c : i64]) : i64
  (let
    [value : i64 7]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (begin
      (set! value 9)
      (if (> c 0)
        a
        (+ a 0)))))

;; 5: the read goes through a second pointer copied from the first.
(define (load-through-copy) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [q : (MutPtr i64) p]
    [a : i64
      (unsafe
        (ptr-read q))]
    (begin
      (set! value 4)
      (+
        a
        (unsafe
          (ptr-read q))))))

;; 6: a narrower local read through a byte pointer.
(define (byte-load-after-set) : i64
  (let
    [value : u8 (cast 1 : u8)]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of value))]
    [a : u8
      (unsafe
        (ptr-read p))]
    (begin
      (set! value (cast 3 : u8))
      (+
        (cast a : i64)
        (cast
          (unsafe
            (ptr-read p))
          : i64)))))

;; A branch load followed by a direct write after the join.
(define (pre-shape [flag : bool]) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [before : i64
      (if flag
        (unsafe
          (ptr-read p))
        0)]
    (set! value 7)
    (+
      before
      (unsafe
        (ptr-read p)))))

(define (store-then-set) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (unsafe
      (ptr-write! p 3))
    (set! value 5)
    (unsafe
      (ptr-read p))))

;; Loop availability must end at a direct write on the back edge.
(define (loop-read-before-set [n : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [sum : i64 0]
    [i : i64 0]
    (while (< i n)
      (set!
        sum
        (+
          sum
          (unsafe
            (ptr-read p))))
      (set! value (+ value 1))
      (set! i (+ i 1)))
    sum))

(define (main) : i64
  (cond
    [(not (= (load-after-set) 6)) 1]
    [(not (= (load-after-branch-set 1) 6)) 2]
    [(not (= (load-after-branch-set 0) 7)) 3]
    [(not (= (loop-read-through 0) 0)) 4]
    [(not (= (loop-read-through 1) 0)) 5]
    [(not (= (loop-read-through 5) 10)) 6]
    [(not (= (load-before-set-kept 1) 7)) 7]
    [(not (= (load-before-set-kept 0) 7)) 8]
    [(not (= (load-through-copy) 5)) 9]
    [(not (= (byte-load-after-set) 4)) 10]
    [(not (= (pre-shape true) 8)) 11]
    [(not (= (pre-shape false) 7)) 12]
    [(not (= (store-then-set) 5)) 13]
    [(not (= (loop-read-before-set 0) 0)) 14]
    [(not (= (loop-read-before-set 1) 0)) 15]
    [(not (= (loop-read-before-set 5) 10)) 16]
    [else 42]))