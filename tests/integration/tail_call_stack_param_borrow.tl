;; #9289: borrowing an incoming SysV Memory-class stack-passed aggregate across
;; a tail call whose outgoing stack arguments overlap its stack slots must not
;; overwrite the borrowed parameter; non-overlapping tail calls (register-only
;; or Box deref into heap storage) stay valid and keep tail jumps.
(defstruct Pair
  (a i64)
  (b i64))

(define (g-arr
  [t : (& t (Array i64 4))]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [x : i64]) : i64
  (+
    (array-ref t 0)
    (- (+ a (+ b (+ c (+ d (+ e x))))) (+ a (+ b (+ c (+ d (+ e x))))))))

(define (g-elem
  [p : (& p i64)]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [x : i64]) : i64
  (+
    (deref p)
    (- (+ a (+ b (+ c (+ d (+ e x))))) (+ a (+ b (+ c (+ d (+ e x))))))))

(define (g-arr-reg [t : (& t (Array i64 4))] [x : i64]) : i64
  (+ (array-ref t 0) (- x x)))

(define (g-box-arr
  [t : (& t (Array (Box i64) 4))]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [x : i64]) : i64
  (+
    (deref (array-ref t 0))
    (- (+ a (+ b (+ c (+ d (+ e x))))) (+ a (+ b (+ c (+ d (+ e x))))))))

(define (g-pair
  [p : (& p Pair)]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [x : i64]) : i64
  (+
    p.a
    (+ p.b (- (+ a (+ b (+ c (+ d (+ e x))))) (+ a (+ b (+ c (+ d (+ e x)))))))))

(define (f-overlap [t : (Array i64 4)] [x : i64]) : i64
  (g-arr (& t) 1 2 3 4 5 x))

(define (f-proj-arr [t : (Array i64 4)] [x : i64]) : i64
  (g-elem (& (array-ref t 0)) 1 2 3 4 5 x))

(define (f-proj-tup [t : (Tuple i64 i64 i64)] [x : i64]) : i64
  (g-elem (& (tuple-ref t 0)) 1 2 3 4 5 x))

(define (f-nonoverlap-reg [t : (Array i64 4)] [x : i64]) : i64
  (g-arr-reg (& t) x))

(define (f-box-deref [t : (Tuple (Box (Array i64 4)) i64 i64)] [x : i64]) : i64
  (g-arr (& (deref (tuple-ref t 0))) 1 2 3 4 5 x))

(define (f-arr-of-box [t : (Array (Box i64) 4)] [x : i64]) : i64
  (g-box-arr (& t) 1 2 3 4 5 x))

(define (f-spilled-pair
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [_f : i64]
  [p : Pair]
  [x : i64]) : i64
  (g-pair (& p) a b c d e x))

(define (main) : i64
  (let
    [r0 : i64 (f-overlap (array 7 7 7 7) 42)]
    [r1 : i64 (f-proj-arr (array 7 1 2 3) 42)]
    [r2 : i64 (f-proj-tup (tuple 7 1 2) 42)]
    [r3 : i64 (f-nonoverlap-reg (array 7 1 2 3) 42)]
    [r4 : i64 (f-box-deref (tuple (box (array 7 1 2 3)) 9 10) 42)]
    [r5 : i64 (f-arr-of-box (array (box 7) (box 1) (box 2) (box 3)) 42)]
    [r6 : i64 (f-spilled-pair 1 2 3 4 5 6 (Pair 3 4) 42)]
    (cond
      [(!= r0 7) 1]
      [(!= r1 7) 2]
      [(!= r2 7) 3]
      [(!= r3 7) 4]
      [(!= r4 7) 5]
      [(!= r5 7) 6]
      [(!= r6 7) 8]
      [else 7])))