;; An exiting operand ends the expression that consumes it: bindings,
;; scrutinees, projections, operators and conditions run nothing after it.
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64))

(defenum Choice
  (Full Wide)
  (Blank))

(define trace : i64
  0)
(define cleaned : i64
  0)

(define (mark [digit : i64]) : i64
  (set! trace (+ (* trace 10) digit))
  digit)

(define (clean-pair [p : Pair]) : unit
  (set! cleaned (+ cleaned p.a)))

(define (clean-count [n : i64]) : unit
  (set! cleaned (+ cleaned n)))

;; Each arm is in tail position and returns 42 from its operand.
(define (returning [mode : i64]) : i64
  (match mode
    ;; let
    [0
      (let
        [p : Pair (Pair (mark 1) (return 42))]
        [_q : i64 (mark 9)]
        p.a)]
    ;; inferred-let
    [1
      (let
        [c (Full (Wide (mark 1) (return 42) (mark 9)))]
        (match c
          [(Full w) w.a]
          [(Blank) 0]))]
    ;; scrutinee
    [2
      (match (Pair (mark 1) (return 42))
        [(Pair a _) (+ a (mark 9))])]
    ;; field
    [3 (+ (Pair (mark 1) (return 42)).a (mark 9))]
    ;; tuple-ref
    [4 (tuple-ref (tuple (mark 1) (return 42)) 0)]
    ;; array-receiver
    [5 (array-ref (array (mark 1) (return 42)) (mark 9))]
    ;; array-index
    [6
      (let
        [a : (Array i64 2) (array 1 2)]
        (array-ref
          a
          (begin
            (mark 1)
            (return 42))))]
    ;; deref
    [7
      (deref
        (box
          (begin
            (mark 1)
            (return 42))))]
    ;; unary
    [8 (neg (Pair (mark 1) (return 42)).a)]
    ;; condition
    [9
      (if (= (Pair (mark 1) (return 42)).a 1)
        (mark 9)
        (mark 9))]
    ;; for-source
    [10
      (let
        [s : i64 0]
        (for [_x (array (mark 1) (return 42))]
          (+= s (mark 9)))
        s)]
    ;; with-resource
    [11
      (with
        ([held (Pair 5 0) clean-pair]
          [_next (Pair (mark 1) (return 42)) clean-pair])
        (+ held.a (mark 9)))]
    ;; cast
    [12
      (cast
        (ann
          (begin
            (mark 1)
            (return 42))
          : i32)
        : i64)]
    [_ 0]))

;; The same operands in value position, consumed by an outer binding.
(define (returning-value [mode : i64]) : i64
  (let
    [result : i64
      (match mode
        [0
          (let
            [p : Pair (Pair (mark 1) (return 42))]
            p.a)]
        [1
          (match (Full (Wide (mark 1) (return 42) (mark 9)))
            [(Full w) w.a]
            [(Blank) 0])]
        [2 (Pair (mark 1) (return 42)).b]
        [3 (tuple-ref (tuple (return 42) (mark 9)) 1)]
        [4
          (if (< (Pair (mark 1) (return 42)).a 0)
            1
            2)]
        [_ 0])]
    (+ result (mark 9))))

;; Exits inside loops: the opt2 loop must not keep code after the exit.
(define (continuing [mode : i64]) : i64
  (let
    [i : i64 0]
    [n : i64 2]
    (while (< i 3)
      (+= i 1)
      (match mode
        [0
          (let
            [p : Pair
              (Pair
                1
                (begin
                  (+= n 10)
                  (continue)))]
            (set! n p.a))]
        [1
          (match (Pair
            1
            (begin
              (+= n 10)
              (continue)))
            [(Pair a _) (set! n a)])]
        [2
          (set!
            n
            (Pair
              1
              (begin
                (+= n 10)
                (continue))).a)]
        [3
          (set!
            n
            (tuple-ref
              (tuple
                (begin
                  (+= n 10)
                  (continue))
                (ann 1 : i64))
              1))]
        [4
          (set!
            n
            (array-ref
              (array
                (ann 1 : i64)
                (begin
                  (+= n 10)
                  (continue)))
              0))]
        [5
          (set!
            n
            (deref
              (box
                (begin
                  (+= n 10)
                  (continue)))))]
        [6
          (set!
            n
            (+
              1
              (begin
                (+= n 10)
                (continue))))]
        [7
          (let
            [x : i64
              (neg
                (begin
                  (+= n 10)
                  (continue)))]
            (set! n x))]
        [8
          (if (begin
            (+= n 10)
            (continue))
            (set! n 5)
            (set! n 6))]
        [9
          (set!
            n
            (cast
              (ann
                (begin
                  (+= n 10)
                  (continue))
                : i32)
              : i64))]
        [10
          (set!
            n
            (cast
              (cast
                (ann
                  (begin
                    (+= n 10)
                    (continue))
                  : i32)
                : f64)
              : i64))]
        [_ unit])
      (set! n 0))
    (+ n 1)))

;; A conditional exit converts the surviving value.
(define (cast-fallthrough [leave : bool]) : i64
  (cast
    (if leave
      (return 42)
      (ann 7 : i32))
    : i64))

;; A cleanup scope around an exiting binding runs exactly once per iteration.
(define (cleanup-loop) : i64
  (let
    [i : i64 0]
    (while (< i 3)
      (+= i 1)
      (with
        ([_held 1 clean-count])
        (let
          [p : Pair
            (Pair
              (begin
                (mark 1)
                (continue))
              (mark 9))]
          (set! cleaned (+ cleaned (* 100 p.a))))))
    i))

(define (main) : i64
  (let
    [mode : i64 0]
    (while (< mode 13)
      (set! trace 0)
      (set! cleaned 0)
      (test.assert-i64-eq (returning mode) 42 "tail operand exit")
      (test.assert-i64-eq trace 1 "only operands before the exit run")
      (test.assert-i64-eq
        cleaned
        (if (= mode 11)
          5
          0)
        "earlier resources clean once")
      (+= mode 1)))
  (let
    [mode : i64 0]
    (while (< mode 5)
      (set! trace 0)
      (test.assert-i64-eq (returning-value mode) 42 "value operand exit")
      (test.assert-i64-eq
        trace
        (if (= mode 3)
          0
          1)
        "value exit skips the outer binding")
      (+= mode 1)))
  (let
    [mode : i64 0]
    (while (< mode 11)
      (test.assert-i64-eq (continuing mode) 33 "loop operand continue")
      (+= mode 1)))
  (test.assert-i64-eq (cast-fallthrough true) 42 "cast operand exit")
  (test.assert-i64-eq (cast-fallthrough false) 7 "cast fallthrough converts")
  (set! trace 0)
  (set! cleaned 0)
  (test.assert-i64-eq (cleanup-loop) 3 "cleanup loop finishes")
  (test.assert-i64-eq cleaned 3 "cleanup runs once per iteration")
  (test.assert-i64-eq trace 111 "binding exits before later operands")
  42)