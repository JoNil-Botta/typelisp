(define call-eval-order-trace : i64
  0)

(define (call-eval-order-mark [digit : i64]) : i64
  (set! call-eval-order-trace (+ (* call-eval-order-trace 10) digit))
  digit)

(define (call-eval-order-sum8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ a b) c) d) e) f) g) h))

(define (call-eval-order-apply8 [fn : (-> i64 i64 i64 i64 i64 i64 i64 i64 i64)]) : i64
  (fn
    (call-eval-order-mark 1)
    (call-eval-order-mark 2)
    (call-eval-order-mark 3)
    (call-eval-order-mark 4)
    (call-eval-order-mark 5)
    (call-eval-order-mark 6)
    (call-eval-order-mark 7)
    (call-eval-order-mark 8)))

(define (call-eval-order-direct-ok?) : bool
  (set! call-eval-order-trace 0)
  (and
    (=
      (call-eval-order-sum8
        (call-eval-order-mark 1)
        (call-eval-order-mark 2)
        (call-eval-order-mark 3)
        (call-eval-order-mark 4)
        (call-eval-order-mark 5)
        (call-eval-order-mark 6)
        (call-eval-order-mark 7)
        (call-eval-order-mark 8))
      36)
    (= call-eval-order-trace 12345678)))

(define (call-eval-order-indirect-ok?) : bool
  (set! call-eval-order-trace 0)
  (and
    (= (call-eval-order-apply8 call-eval-order-sum8) 36)
    (= call-eval-order-trace 12345678)))

(define (snapshot-first [a : i64] [_b : i64]) : i64
  a)

(define (snapshot-digits [a : i64] [b : i64] [c : i64]) : i64
  (+ c (+ (* b 10) (* a 100))))

(define (snapshot-bool [a : bool] [_b : bool]) : bool
  a)

(define (snapshot-u8 [a : u8] [_b : u8]) : u8
  a)

(define (snapshot-i32 [a : i32] [_b : i32]) : i32
  a)

(define (snapshot-f32 [a : f32] [_b : f32]) : f32
  a)

(define (snapshot-f64 [a : f64] [_b : f64]) : f64
  a)

(define (snapshot-unit [a : i64] [_effect : unit]) : i64
  a)

(define (snapshot-callee-first [_effect : unit]) : i64
  42)

(define (snapshot-callee-second [_effect : unit]) : i64
  13)

(defstruct SnapshotCallable
  (function (-> unit i64)))

(define (call-eval-order-tail-callee [fn : (-> unit i64)]) : i64
  (fn (set! fn snapshot-callee-second)))

(define (call-eval-order-callee-ok?) : bool
  (let
    [fn : (-> unit i64) snapshot-callee-first]
    [direct : i64 (fn (set! fn snapshot-callee-second))]
    [changed : i64 (fn unit)]
    [wrapped
      : i64
      ;; This transparent wrapper exercises general callee-expression lowering.
      ;; lint-allow: single-begin
      ((begin
          fn)
        (set! fn snapshot-callee-first))]
    [owner : SnapshotCallable (SnapshotCallable snapshot-callee-first)]
    [projected : i64
      (owner.function (set! owner.function snapshot-callee-second))]
    [count : i64 0]
    [once : i64
      ((begin
          (set! count (+ count 1))
          fn)
        (begin
          (set! fn snapshot-callee-second)
          unit))]
    ;; A later argument replaces the callee through its address.
    [addressed : i64
      (begin
        (set! fn snapshot-callee-first)
        (fn
          (unsafe
            (ptr-write! (ptr-addr-of fn) snapshot-callee-second))))]
    [addressed-changed : i64 (fn unit)]
    (and
      (= direct 42)
      (= changed 13)
      (= wrapped 13)
      (= projected 42)
      (= (owner.function unit) 13)
      (= once 42)
      (= count 1)
      (= addressed 42)
      (= addressed-changed 13)
      (= (call-eval-order-tail-callee snapshot-callee-first) 42))))

(define (snapshot-writeback [a : i64] [out : (&mut out i64)]) : i64
  (begin
    (set! (deref out) 77)
    a))

;; The explicit local snapshots specify the result independently of argument
;; collection. Merely preserving the side-effect trace misses this bug (#8433).
(define (call-eval-order-snapshots-ok?) : bool
  (let
    [x : i64 1]
    [saved : i64 x]
    [direct : i64
      (snapshot-first
        x
        (begin
          (set! x 99)
          0))]
    [direct-ok : bool (and (= direct saved) (= x 99))]
    [fn : (-> i64 i64 i64) snapshot-first]
    [indirect : i64
      (fn
        x
        (begin
          (set! x 5)
          0))]
    [indirect-ok : bool (and (= indirect 99) (= x 5))]
    [nested : i64
      (snapshot-first
        x
        (snapshot-first
          (begin
            (set! x 6)
            x)
          (begin
            (set! x 7)
            0)))]
    [nested-ok : bool (and (= nested 5) (= x 7))]
    [digits : i64
      (snapshot-digits
        x
        (begin
          (set! x 8)
          x)
        (begin
          (set! x 9)
          x))]
    [digits-ok : bool (and (= digits 789) (= x 9))]
    [branched : i64
      (snapshot-first
        (if (> x 0)
          x
          0)
        (begin
          (set! x 10)
          0))]
    [branch-ok : bool (and (= branched 9) (= x 10))]
    [effect : i64 (snapshot-unit x (set! x 11))]
    [effect-ok : bool (and (= effect 10) (= x 11))]
    [writeback : i64 (snapshot-writeback x (&mut x))]
    (and
      direct-ok
      indirect-ok
      nested-ok
      digits-ok
      branch-ok
      effect-ok
      (= writeback 11)
      (= x 77))))

(define (call-eval-order-widths-ok?) : bool
  (let
    [flag : bool true]
    [a : u8 (cast 3 : u8)]
    [b : i32 (cast -4 : i32)]
    [c : f32 (cast 1.25 : f32)]
    [d : f64 2.5]
    [flag-old : bool
      (snapshot-bool
        flag
        (begin
          (set! flag false)
          false))]
    [a-old : u8
      (snapshot-u8
        a
        (begin
          (set! a (cast 9 : u8))
          a))]
    [b-old : i32
      (snapshot-i32
        b
        (begin
          (set! b (cast 9 : i32))
          b))]
    [c-old : f32
      (snapshot-f32
        c
        (begin
          (set! c (cast 9.0 : f32))
          c))]
    [d-old : f64
      (snapshot-f64
        d
        (begin
          (set! d 9.0)
          d))]
    (and
      flag-old
      (not flag)
      (= a-old (cast 3 : u8))
      (= a (cast 9 : u8))
      (= b-old (cast -4 : i32))
      (= b (cast 9 : i32))
      (= c-old (cast 1.25 : f32))
      (= c (cast 9.0 : f32))
      (= d-old 2.5)
      (= d 9.0))))

(define (call-eval-order-loop-ok?) : bool
  (let
    [x : i64 1]
    [iteration : i64 0]
    [ok : bool true]
    (begin
      (while (< iteration 3)
        (let
          [saved : i64 x]
          [result : i64
            (snapshot-first
              x
              (begin
                (set! x (+ x 1))
                0))]
          (begin
            (set! ok (and ok (= result saved) (= x (+ saved 1))))
            (set! iteration (+ iteration 1)))))
      (and ok (= x 4)))))

(defstruct SnapshotPair
  (a i64)
  (b i64))

(defstruct SnapshotTriple
  (a i64)
  (b i64)
  (c i64))

(defstruct SnapshotNested
  (value SnapshotTriple)
  (effect i64))

(define (snapshot-pair [value : SnapshotPair] [_effect : unit]) : i64
  (+ value.a value.b))

(define (snapshot-triple [value : SnapshotTriple] [_effect : unit]) : i64
  (+ value.a (+ value.b value.c)))

;; A pointer to inline bytes is a place, not the earlier argument's value.
;; Both the register group and memory-class cases retain every original field.
(define (call-eval-order-aggregates-ok?) : bool
  (let
    [pair : SnapshotPair (SnapshotPair 20 22)]
    [triple : SnapshotTriple (SnapshotTriple 10 12 20)]
    [pair-sum : i64 (snapshot-pair pair (set! pair.b 99))]
    [triple-sum : i64 (snapshot-triple triple (set! triple.c 99))]
    [fn : (-> SnapshotTriple unit i64) snapshot-triple]
    [indirect : i64 (fn triple (set! triple.a 77))]
    [nested : SnapshotNested
      (SnapshotNested
        triple
        (begin
          (set! triple.b 88)
          0))]
    (and
      (= pair-sum 42)
      (= pair.b 99)
      (= triple-sum 42)
      (= indirect 121)
      (= nested.value.a 77)
      (= nested.value.b 12)
      (= nested.value.c 99)
      (= triple.b 88))))

(define (call-eval-order-operators-ok?) : bool
  (let
    [x : i64 42]
    [sum : i64
      (+
        x
        (begin
          (set! x 99)
          0))]
    [difference : i64
      (-
        x
        (begin
          (set! x 5)
          1))]
    [less : bool
      (<
        x
        (begin
          (set! x 9)
          6))]
    [same : bool
      (=
        x
        (begin
          (set! x 10)
          9))]
    [decimal : f64 1.5]
    [decimal-sum : f64
      (+
        decimal
        (begin
          (set! decimal 2.0)
          0.5))]
    [pair : SnapshotPair (SnapshotPair 20 22)]
    [pair-same : bool
      (=
        pair
        (begin
          (set! pair.a 99)
          (SnapshotPair 20 22)))]
    [untouched : i64 0]
    [skip-and : bool
      (and
        false
        (begin
          (set! untouched 1)
          true))]
    [skip-or : bool
      (or
        true
        (begin
          (set! untouched 2)
          false))]
    (and
      (= sum 42)
      (= difference 98)
      less
      same
      (= x 10)
      (= decimal-sum 2.0)
      (= decimal 2.0)
      pair-same
      (= pair.a 99)
      (not skip-and)
      skip-or
      (= untouched 0))))

(define (main) : i64
  (if (and
    (call-eval-order-direct-ok?)
    (call-eval-order-indirect-ok?)
    (call-eval-order-snapshots-ok?)
    (call-eval-order-callee-ok?)
    (call-eval-order-widths-ok?)
    (call-eval-order-loop-ok?)
    (call-eval-order-aggregates-ok?)
    (call-eval-order-operators-ok?))
    42
    1))