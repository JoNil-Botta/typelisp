;; By-value bindings own their values (SPEC "match scrutinees", by-value
;; parameters, closure captures). Memory-class aggregates are lowered as
;; addresses, so each case pins a route where a binding could otherwise alias
;; storage it does not own: a pattern binding and its scrutinee, a parameter
;; and the caller's argument, a closure capture and a re-entrant call. The
;; lowering may share storage only with evidence that neither side is written.
(import stdlib.io)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defstruct Outer
  (inner Triple)
  (tag i64))

(defenum Slot
  (Full Triple)
  (Empty))

(define global-triple : Triple
  (Triple 1 2 3))

(define (first-a [t : Triple] [_n : i64]) : i64
  t.a)

;; A write through a payload binding does not reach the scrutinee.
(define (payload-write-case) : i64
  (let
    [s : Slot (Slot.Full (Triple 1 2 3))]
    (begin
      (match s
        [(Slot.Full v) (set! v.a 100)]
        [(Slot.Empty) unit])
      (match s
        [(Slot.Full v) v.a]
        [(Slot.Empty) 0]))))

;; A write to the scrutinee does not change a live payload binding.
(define (scrutinee-write-case) : i64
  (let
    [s : Slot (Slot.Full (Triple 5 6 7))]
    (match s
      [(Slot.Full v)
        (begin
          (set! s (Slot.Full (Triple 50 60 70)))
          v.a)]
      [(Slot.Empty) 0])))

;; A payload binding passed before an operand that writes the scrutinee.
(define (payload-argument-case) : i64
  (let
    [s : Slot (Slot.Full (Triple 8 6 7))]
    (match s
      [(Slot.Full v)
        (first-a
          v
          (begin
            (set! s (Slot.Full (Triple 80 60 70)))
            0))]
      [(Slot.Empty) 0])))

;; A catch-all binding is a value too.
(define (catch-all-case) : i64
  (let
    [t : Triple (Triple 11 12 13)]
    (match t
      [other
        (begin
          (set! t.a 110)
          (set! other.b 120)
          (+ other.a t.b))])))

;; A struct-pattern field binding.
(define (struct-field-case) : i64
  (let
    [o : Outer (Outer (Triple 21 22 23) 0)]
    (match o
      [(Outer inner _)
        (begin
          (set! o.inner.a 210)
          inner.a)])))

;; A heap scrutinee: the arm's write goes through the array handle.
(define (heap-scrutinee-case) : i64
  (let
    [slots : (__tl_dyn-array Slot) (__tl_make-array Slot 1)]
    (begin
      (set! (array-ref slots 0) (Slot.Full (Triple 31 32 33)))
      (match (array-ref slots 0)
        [(Slot.Full v)
          (begin
            (set! (array-ref slots 0) (Slot.Full (Triple 310 320 330)))
            v.a)]
        [(Slot.Empty) 0]))))

;; A callee's write to its parameter does not reach the caller.
(define (bump-param [t : Triple]) : i64
  (begin
    (set! t.a 99)
    t.a))

(define (param-write-case) : i64
  (let
    [t : Triple (Triple 41 42 43)]
    (+ (bump-param t) t.a)))

;; ... including a write through a mutable borrow or a raw address of it.
(define (bump-a! [t : (&mut t Triple)]) : i64
  (begin
    (set! t.a (+ t.a 100))
    0))

(define (bump-param-borrowed [t : Triple]) : i64
  (begin
    (bump-a! (&mut t))
    t.a))

(define (param-borrow-write-case) : i64
  (let
    [t : Triple (Triple 91 92 93)]
    (+ (bump-param-borrowed t) t.a)))

(define (bump-param-raw [t : Triple]) : i64
  (begin
    (unsafe
      (ptr-write! (ptr-addr-of t) (Triple 95 96 97)))
    t.a))

(define (param-raw-write-case) : i64
  (let
    [t : Triple (Triple 94 92 93)]
    (+ (bump-param-raw t) t.a)))

;; A callee that never writes its parameter still sees the value from the
;; call, even when it writes the global that was passed.
(define (read-after-global-write [t : Triple]) : i64
  (begin
    (set! global-triple (Triple 510 520 530))
    t.a))

(define (global-argument-case) : i64
  (begin
    (set! global-triple (Triple 51 52 53))
    (read-after-global-write global-triple)))

;; ... or the array element that was passed.
(define (read-after-element-write
  [t : Triple]
  [items : (__tl_dyn-array Triple)]) : i64
  (begin
    (set! (array-ref items 0) (Triple 610 620 630))
    t.a))

(define (element-argument-case) : i64
  (let
    [items : (__tl_dyn-array Triple) (__tl_make-array Triple 1)]
    (begin
      (set! (array-ref items 0) (Triple 61 62 63))
      (read-after-element-write (array-ref items 0) items))))

;; A forwarded parameter keeps the caller's guarantee transitively.
(define (forward-param [t : Triple]) : i64
  (read-after-global-write t))

(define (forwarded-global-case) : i64
  (begin
    (set! global-triple (Triple 71 72 73))
    (forward-param global-triple)))

;; A raw view `(ptr-read (ptr-addr-of x))` is not a borrow the checker
;; tracks, so the same call can also pass `&mut x`. The by-value parameter
;; still holds the value from the call.
(define (write-then-read [m : (&mut m Triple)] [t : Triple]) : i64
  (begin
    (set! m.a 990)
    t.a))

(define (raw-view-argument-case) : i64
  (let
    [x : Triple (Triple 99 98 97)]
    (write-then-read
      (&mut x)
      (unsafe
        (ptr-read (ptr-addr-of x))))))

;; A closure capture lives in the shared closure environment; a re-entrant
;; call can write it while an earlier operand still refers to it.
(define (idle [n : i64]) : i64
  n)

(define hook : (-> i64 i64)
  idle)

(define (make-reentrant) : (-> i64 i64)
  (let
    [t : Triple (Triple 81 82 83)]
    (lambda ([n : i64]) : i64
      (if (= n 0)
        (begin
          (set! t.a 810)
          0)
        (first-a t (hook 0))))))

(define (reentrant-capture-case) : i64
  (begin
    (set! hook (make-reentrant))
    (hook 1)))

(define (main) : i64
  (let
    [results : i64
      (+
        (if (= (payload-write-case) 1)
          1
          0)
        (if (= (scrutinee-write-case) 5)
          2
          0)
        (if (= (payload-argument-case) 8)
          4
          0)
        (if (= (catch-all-case) 23)
          8
          0)
        (if (= (struct-field-case) 21)
          16
          0)
        (if (= (heap-scrutinee-case) 31)
          32
          0)
        (if (= (param-write-case) 140)
          64
          0)
        (if (= (global-argument-case) 51)
          128
          0)
        (if (= (element-argument-case) 61)
          256
          0)
        (if (= (forwarded-global-case) 71)
          512
          0)
        (if (= (reentrant-capture-case) 81)
          1024
          0)
        (if (= (param-borrow-write-case) 282)
          2048
          0)
        (if (= (param-raw-write-case) 189)
          4096
          0)
        (if (= (raw-view-argument-case) 99)
          8192
          0))]
    (begin
      (io.print-format "{}\n" results)
      (if (= results 16383)
        42
        results))))