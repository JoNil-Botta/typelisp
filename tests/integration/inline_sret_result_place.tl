;; Inlining an sret callee preserves the caller-owned result place (#7144).
;;
;; Every `srp-` producer below has exactly one call site, is acyclic, carries a
;; call, and is padded by a guard ladder past the cost model's block fuel, so at
;; opt2 the sole-call tier absorbs it whole: the result is written through the
;; hidden sret parameter straight into the storage the caller reserved for the
;; call. The cases cover a direct constructor, a result built across branches,
;; an early return, a body that writes its own by-value parameter (the staged
;; clone), a MoveOnly payload, a structural tuple result, a nested sole-call
;; chain, a tail call that forwards its sret, an enum result, an argument that
;; feeds the result place (`(set! b (f b))`) and two views of one result.
;;
;; Each window measures `profile.alloc-total` around the calls only: absorption
;; must not introduce an allocation. `main` yields 42 only if every window is
;; zero and every value is intact at every optimization level.
(import stdlib.profile)
(import stdlib.string)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct Named
  (label String)
  (a i64)
  (b i64)
  (c i64))

(defenum Shape
  (Circle i64 i64 i64)
  (Boxed Big)
  (Empty))

;; Eight forward guard arms and no back edge: enough blocks to take a body past
;; the cost model while leaving it acyclic, so the sole-call tier decides it.
(defmacro (srp-ladder [salt : Expr] [bias : Expr]) : Expr
  `(cond
    [(< ,salt 2) (set! ,bias 2)]
    [(< ,salt 4) (set! ,bias 4)]
    [(< ,salt 8) (set! ,bias 8)]
    [(< ,salt 16) (set! ,bias 16)]
    [(< ,salt 32) (set! ,bias 32)]
    [(< ,salt 64) (set! ,bias 64)]
    [(< ,salt 128) (set! ,bias 128)]
    [else (set! ,bias 256)]))

;; Recursive, so no tier inlines it: every producer keeps a real call.
(define (srp-opaque [n : i64]) : i64
  (if (<= n 0)
    1
    (+ 1 (srp-opaque (- n 1)))))

(define (srp-direct [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (Big x (+ x bias) (+ x 2) (srp-opaque 3)))))

(define (srp-branches [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (if (> x bias)
        (Big x bias (srp-opaque 1) 0)
        (Big bias x 0 (srp-opaque 2))))))

(define (srp-early [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (when (> x 100) (return (Big 7 7 7 (srp-opaque 0))))
      (Big x bias (srp-opaque 4) 9))))

;; Writes its own by-value parameter slot, so the clone stages the arguments.
(define (srp-mutating [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (set! x (+ x (srp-opaque 1)))
      (srp-ladder salt bias)
      (set! salt (+ salt x))
      (Big x salt bias (+ x bias)))))

(define (srp-named [label : String] [x : i64] [salt : i64]) : Named
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (Named label x (+ x bias) (srp-opaque 2)))))

(define (srp-tuple [x : i64] [salt : i64]) : (Tuple i64 i64 i64 i64)
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (tuple x bias (srp-opaque 1) (+ x 3)))))

(define (srp-inner [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (Big (srp-opaque 0) x bias (+ x 1)))))

(define (srp-outer [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    [inner : Big (srp-inner (+ x 1) salt)]
    (begin
      (srp-ladder salt bias)
      (Big inner.d inner.c inner.b (+ inner.a bias)))))

(define (srp-forwarded [x : i64] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (Big (+ x 1) (+ x 2) bias (srp-opaque 5)))))

;; The tail call forwards this function's own sret to its callee.
(define (srp-forward [x : i64] [salt : i64]) : Big
  (srp-forwarded (* x 2) salt))

(define (srp-shape [x : i64] [salt : i64]) : Shape
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (cond
        [(> x 10) (Shape.Circle x bias (srp-opaque 1))]
        [(> x 0) (Shape.Boxed (Big x bias x (srp-opaque 2)))]
        [else (Shape.Empty)]))))

;; The fields are read in the reverse of the order the result is written, so a
;; result place shared with the argument would be read after it was written.
(define (srp-bump [b : Big] [salt : i64]) : Big
  (let
    [bias : i64 0]
    (begin
      (srp-ladder salt bias)
      (Big b.d b.c b.b (+ b.a (srp-opaque 0))))))

(define (srp-sum-ref [r : (& r Big)]) : i64
  (+ r.a (+ r.b (+ r.c r.d))))

;; Deep enough to overwrite any frame storage a returned value could alias.
(define (srp-clobber [n : i64]) : i64
  (let
    [b : Big (Big n n n n)]
    (if (<= n 0)
      b.a
      (+ b.d (srp-clobber (- n 1))))))

(define (case-straight) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [direct : Big (srp-direct 5 3)]
    [high : Big (srp-branches 50 20)]
    [early : Big (srp-early 200 1)]
    [mutated : Big (srp-mutating 10 5)]
    [after : i64 (profile.alloc-total)]
    (begin
      (srp-clobber 16)
      (unless (= after before) (return 1))
      (unless (= (+ direct.a (+ direct.b (+ direct.c direct.d))) 25) (return 2))
      (unless (= (+ high.a (+ high.b (+ high.c high.d))) 84) (return 3))
      (unless (= (+ early.a (+ early.b (+ early.c early.d))) 22) (return 4))
      (unless
        (= (+ mutated.a (+ mutated.b (+ mutated.c mutated.d))) 57)
        (return 5))
      0)))

(define (case-payloads) : i64
  (let
    [label : String (string.copy "sret")]
    [before : i64 (profile.alloc-total)]
    [named : Named (srp-named label 4 9)]
    [wide : (Tuple i64 i64 i64 i64) (srp-tuple 6 40)]
    [circle : Shape (srp-shape 11 3)]
    [after : i64 (profile.alloc-total)]
    (begin
      (srp-clobber 16)
      (unless (= after before) (return 11))
      (unless (string.eq named.label "sret") (return 12))
      (unless (= (+ named.a (+ named.b named.c)) 27) (return 13))
      (unless
        (=
          (+
            (tuple-ref wide 0)
            (+ (tuple-ref wide 1) (+ (tuple-ref wide 2) (tuple-ref wide 3))))
          81)
        (return 14))
      (match circle
        [(Shape.Circle r bias n) (unless (= (+ r (+ bias n)) 17) (return 15))]
        [(Shape.Boxed _) (return 16)]
        [(Shape.Empty) (return 17)])
      0)))

(define (case-chains) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [outer : Big (srp-outer 3 1)]
    [forwarded : Big (srp-forward 4 70)]
    [after : i64 (profile.alloc-total)]
    (begin
      (srp-clobber 16)
      (unless (= after before) (return 21))
      (unless (= (+ outer.a (+ outer.b (+ outer.c outer.d))) 14) (return 22))
      (unless
        (= (+ forwarded.a (+ forwarded.b (+ forwarded.c forwarded.d))) 153)
        (return 23))
      0)))

(define (case-views) : i64
  (let
    [b : Big (Big 1 2 3 4)]
    [before : i64 (profile.alloc-total)]
    [_bump : unit (set! b (srp-bump b 5))]
    [after : i64 (profile.alloc-total)]
    (begin
      (srp-clobber 16)
      (unless (= after before) (return 31))
      (unless (= b.a 4) (return 32))
      (unless (= b.b 3) (return 33))
      (unless (= b.c 2) (return 34))
      (unless (= b.d 2) (return 35))
      (unless (= (srp-sum-ref (& b)) 11) (return 36))
      0)))

(define (main) : i64
  (let
    [straight : i64 (case-straight)]
    [payloads : i64 (case-payloads)]
    [chains : i64 (case-chains)]
    [views : i64 (case-views)]
    (cond
      [(not (= straight 0)) straight]
      [(not (= payloads 0)) payloads]
      [(not (= chains 0)) chains]
      [(not (= views 0)) views]
      [else 42])))