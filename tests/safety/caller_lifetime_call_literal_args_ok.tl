;; A callee's formal names the callee's own lifetimes, which every call
;; instantiates afresh: in a body that also binds or reads a name spelled like
;; them, the spelling does not name that binding inside literal and variable
;; arguments, with or without literals that need the formal's type.
(defstruct PairBox
  (:lifetimes a)
  (pair (Tuple (& a i64) i64)))

(defstruct BoxBox
  (:lifetimes a)
  (inner (Box (& a i64))))

(defstruct ArrBox
  (:lifetimes a)
  (items (Array (& a i64) 1)))

(define (fst [pr : (Tuple (& a i64) i64)]) : (& a i64)
  (tuple-ref pr 0))

(define (pair-of [a : i64] [p : (& a i64)]) : (PairBox a)
  (PairBox (tuple p a)))

(define (pair-borrowed [a : i64] [p : (& a i64)]) : (PairBox a)
  (PairBox (tuple (& (deref p)) a)))

(define (pair-store [a : i64] [p : (& a i64)] [b : (&mut a (PairBox a))]) : unit
  (set! (deref b) (PairBox (tuple p a))))

(define (box-of [a : i64] [p : (& a i64)]) : (BoxBox a)
  (BoxBox (box p)))

(define (array-of [a : i64] [p : (& a i64)]) : (ArrBox a)
  (ArrBox (array p)))

(define (first-of [a : i64] [p : (& a i64)]) : (& a i64)
  (fst (tuple p a)))

(define (pair-literal [a : i64] [p : (& a i64)]) : (PairBox a)
  (PairBox (tuple p 1)))

(define (first-literal [a : i64] [p : (& a i64)]) : (& a i64)
  (fst (tuple p 1)))

(define (store-literal [a : i64] [p : (& a i64)] [b : (&mut a (PairBox a))]) : unit
  (set! (deref b) (PairBox (tuple p 1))))

(define (local-literal [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [pb (PairBox (tuple (& a) 1))]
    (deref (tuple-ref pb.pair 0))))

(define (a) : i64
  1)

(define (pair-with-global [p : (& a i64)]) : (PairBox a)
  (PairBox (tuple p (a))))

(define (local-pair [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [pb (PairBox (tuple (& a) 0))]
    (deref (tuple-ref pb.pair 0))))

(define (main) : i64
  (let
    [x : i64 5]
    [pb (pair-of 1 (& x))]
    (deref (tuple-ref pb.pair 0))))