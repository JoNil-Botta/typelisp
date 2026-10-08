;; by_value_param_private_storage.tl - a by-value struct or enum parameter is
;; private callee storage (#7901, SPEC 4.7.2).
;;
;; A memory-class aggregate is passed as the address of the caller's storage.
;; A callee that writes its parameter in place must not change the caller's
;; value, and a callee that only reads it must not see the caller's storage
;; change during the call. Each check below returns its own code on failure;
;; all passing exits 42.
(defstruct Triple
  (x i64)
  (y i64)
  (z i64))

(defstruct Outer
  (inner Triple)
  (tag i64))

(defenum Shape
  (Point Triple)
  (Empty))

;; A field write.
(define (bump [t : Triple]) : i64
  (set! t.x 99)
  t.x)

;; A `&mut` borrow of the parameter, handed to a mutator.
(define (zero-x! [t : (&mut t Triple)]) : unit
  (set! t.x 0))

(define (bump-through-ref [t : Triple]) : i64
  (zero-x! (&mut t))
  (+ t.x 5))

;; A payload bound by a by-value match, written through the binding.
(define (bump-payload [s : Shape]) : i64
  (match s
    [(Point p)
      (set! p.x 40)
      p.x]
    [(Empty) 0]))

;; A parameter written and then forwarded by a tail call.
(define (count-up [t : Triple] [n : i64]) : i64
  (if (= n 0)
    t.x
    (begin
      (set! t.x (+ t.x 1))
      (count-up t (- n 1)))))

;; The same root passed by value and by `&mut` in one call.
(define (read-after-write [t : Triple] [m : (&mut m Triple)]) : i64
  (set! m.x 50)
  t.x)

;; A later argument that writes an earlier one's root while it is evaluated.
(define (bump-x! [m : (&mut m Triple)]) : i64
  (set! m.x 60)
  0)

(define (read-x-plus [t : Triple] [n : i64]) : i64
  (+ t.x n))

;; A global argument that the callee's own callee changes.
(define shared : Triple
  (Triple 1 2 3))

(define (poke-shared) : unit
  (set! shared.x 70))

(define (read-after-poke [t : Triple]) : i64
  (poke-shared)
  t.x)

;; A field of a global, passed by value, that the callee's callee changes.
(defstruct Holder
  (inner Triple)
  (tag i64))

(define held : Holder
  (Holder (Triple 5 6 7) 0))

(define (poke-held) : unit
  (set! held.inner.x 80))

(define (read-after-poke-held [t : Triple]) : i64
  (poke-held)
  t.x)

;; An element of a global fixed array, and of a global tuple, passed by value,
;; that the callee's callee replaces.
(define (make-tarr) : (Array Triple 2)
  (array (Triple 9 8 7) (Triple 6 5 4)))

(define tarr : (Array Triple 2)
  (make-tarr))

(define (poke-tarr) : unit
  (set! (array-ref tarr 1) (Triple 70 0 0)))

(define (read-after-poke-tarr [t : Triple]) : i64
  (poke-tarr)
  t.x)

(define tpair : (Tuple Triple i64)
  (tuple (Triple 9 8 7) 1))

(define (poke-tpair) : unit
  (set! tpair (tuple (Triple 70 0 0) 2)))

(define (read-after-poke-tpair [t : Triple]) : i64
  (poke-tpair)
  t.x)

;; A parameter that shadows a global of another type.
(define tw : i64
  7)

(define (bump-shadow [tw : Triple]) : i64
  (set! tw.x 99)
  tw.x)

;; The same local passed twice and only read needs no copy.
(define (add-x [t : Triple] [u : Triple]) : i64
  (+ t.x u.x))

(define (main) : i64
  (let
    [a : Triple (Triple 1 2 3)]
    [b : Triple (Triple 7 8 9)]
    [c : Shape (Point (Triple 4 5 6))]
    [d : Triple (Triple 10 0 0)]
    [e : Triple (Triple 1 2 3)]
    [lambda-bump : (-> Triple i64)
      (lambda ([t : Triple]) : i64
        (set! t.y 77)
        t.y)]
    [base : i64 3]
    [closure-bump : (-> Triple i64)
      (lambda ([t : Triple]) : i64
        (set! t.z (+ base 80))
        t.z)]
    ;; A lambda body's own local, written by another argument of one call.
    [lambda-conflict : (-> i64)
      (lambda () : i64
        (let
          [f : Triple (Triple 3 0 0)]
          (+ (read-x-plus f (bump-x! (&mut f))) (* 100 f.x))))]
    (cond
      [(not (= (bump a) 99)) 1]
      [(not (= a.x 1)) 2]
      [(not (= (bump-through-ref b) 5)) 3]
      [(not (= b.x 7)) 4]
      [(not (= (bump-payload c) 40)) 5]
      [(not
          (match c
            [(Point p) (= p.x 4)]
            [(Empty) false]))
        6]
      [(not (= (count-up d 5) 15)) 7]
      [(not (= d.x 10)) 8]
      [(not (= (read-after-write e (&mut e)) 1)) 9]
      [(not (= e.x 50)) 10]
      [(not (= (read-after-poke shared) 1)) 11]
      [(not (= shared.x 70)) 12]
      [(not (= (lambda-bump a) 77)) 13]
      [(not (= a.y 2)) 14]
      [(not (= (closure-bump a) 83)) 15]
      [(not (= a.z 3)) 16]
      [(not (= (add-x a a) 2)) 17]
      [(not (= (read-x-plus d (bump-x! (&mut d))) 10)) 18]
      [(not (= d.x 60)) 19]
      [(not (= (read-after-poke-held held.inner) 5)) 20]
      [(not (= held.inner.x 80)) 21]
      ;; A field of a global that another argument borrows `&mut`.
      [(not (= (read-x-plus held.inner (bump-x! (&mut held.inner))) 80)) 22]
      [(not (= held.inner.x 60)) 23]
      [(not (= (lambda-conflict) 6003)) 24]
      [(not (= (+ (bump-shadow a) tw) 106)) 25]
      [(not (= a.x 1)) 26]
      [(not (= (read-after-poke-tarr (array-ref tarr 1)) 6)) 27]
      [(not (= (read-x-plus (array-ref tarr 1) 0) 70)) 28]
      [(not (= (read-after-poke-tpair (tuple-ref tpair 0)) 9)) 29]
      [(not (= (read-x-plus (tuple-ref tpair 0) 0) 70)) 30]
      [else 42])))