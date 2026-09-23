;; Refs #7972: a local whose address escapes can be written through that
;; address, so no def of it may be forwarded past the escape. Every case reads
;; the local directly after a store through its address and must see the
;; stored value at each optimization level. The callees recurse so the store
;; stays behind a call.
(define (write-seven [p : (MutPtr i64)] [depth : i64]) : i32
  (if (> depth 0)
    (write-seven p (- depth 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

(define (write-true [p : (MutPtr bool)] [depth : i64]) : unit
  (if (> depth 0)
    (write-true p (- depth 1))
    (unsafe
      (ptr-write! p true))))

;; The Win32 out-parameter shape: branch on the status, then on the value
;; (sccp and the global copy both folded the read to the initializer).
(define (branch-after-call [depth : i64]) : i64
  (let
    [value : i64 0]
    [status : i32
      (write-seven
        (unsafe
          (ptr-addr-of value))
        depth)]
    (if (= status (cast 0 : i32))
      1
      (if (<= value 0)
        2
        (+ 35 value)))))

;; No branch on the value: the read feeds arithmetic directly.
(define (straight-after-call [depth : i64]) : i64
  (let
    [value : i64 0]
    [status : i32
      (write-seven
        (unsafe
          (ptr-addr-of value))
        depth)]
    (+ (+ 34 value) (cast status : i64))))

;; A bool local is itself the branch condition.
(define (flag-after-call [depth : i64]) : i64
  (let
    [flag : bool false]
    (begin
      (write-true
        (unsafe
          (ptr-addr-of flag))
        depth)
      (if flag
        42
        3))))

;; The loop header reads the local before the body takes its address. The
;; round cap keeps a regression a wrong exit code rather than a hang.
(define (loop-until-written [depth : i64]) : i64
  (let
    [value : i64 0]
    [rounds : i64 0]
    (begin
      (while (and (= value 0) (< rounds 4))
        (begin
          (write-seven
            (unsafe
              (ptr-addr-of value))
            depth)
          (set! rounds (+ rounds 1))))
      (+ (* value 5) (+ rounds 6)))))

;; A parameter-seeded local: the global copy forwarded the parameter.
(define (seeded-after-call [depth : i64] [seed : i64]) : i64
  (let
    [value : i64 seed]
    (begin
      (write-seven
        (unsafe
          (ptr-addr-of value))
        depth)
      (+ 35 value))))

;; A copy taken before the write keeps the old value; the local does not.
(define (snapshot-before-write [depth : i64] [seed : i64]) : i64
  (let
    [value : i64 seed]
    [before : i64 value]
    (begin
      (write-seven
        (unsafe
          (ptr-addr-of value))
        depth)
      (+ (* before 10) value))))

;; The same expression before and after the write differs (affine folding
;; rewrote the second through the parameter).
(define (expr-before-and-after [depth : i64] [seed : i64]) : i64
  (let
    [value : i64 seed]
    [first : i64 (+ value 1)]
    (begin
      (write-seven
        (unsafe
          (ptr-addr-of value))
        depth)
      (let
        [second : i64 (+ value 1)]
        (+ (* first 10) second)))))

;; A store through the address in the same block as two equal expressions
;; (global CSE reused the first).
(define (expr-around-store [seed : i64]) : i64
  (let
    [value : i64 seed]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [first : i64 (* value 3)]
    (begin
      (unsafe
        (ptr-write! p 9))
      (let
        [second : i64 (* value 3)]
        (+ first second)))))

;; A counter only ever updated through its address.
(define (count-through-address [rounds : i64]) : i64
  (let
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (< i rounds)
        (let
          [p : (MutPtr i64)
            (unsafe
              (ptr-addr-of count))]
          (begin
            (unsafe
              (ptr-write!
                p
                (+
                  (unsafe
                    (ptr-read p))
                  7)))
            (set! i (+ i 1)))))
      count)))

(define (main) : i64
  (cond
    [(not (= (branch-after-call 3) 42)) 10]
    [(not (= (straight-after-call 3) 42)) 11]
    [(not (= (flag-after-call 3) 42)) 12]
    [(not (= (loop-until-written 3) 42)) 13]
    [(not (= (seeded-after-call 3 2) 42)) 14]
    [(not (= (snapshot-before-write 3 2) 27)) 15]
    [(not (= (expr-before-and-after 3 2) 38)) 16]
    [(not (= (expr-around-store 5) 42)) 17]
    [(not (= (count-through-address 6) 42)) 18]
    [else 42]))