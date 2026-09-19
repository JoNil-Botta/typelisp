;; Returning an aggregate never allocates merely because the value crosses a
;; function boundary (#7070). Every case measures `profile.alloc-total` around
;; calls whose only work is building and returning an aggregate; owned payloads
;; and closure environments are created outside the measured window because
;; those allocations are explicit. `main` yields 42 only if every window is
;; exactly zero bytes and every returned value is intact.
(import stdlib.profile)
(import stdlib.string)

(defstruct Small
  (a i64)
  (b i64))

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct Nested
  (left Big)
  (right Small)
  (tag i64))

(defstruct Named
  (label String)
  (pad0 i64)
  (pad1 i64)
  (pad2 i64))

(defenum Shape
  (Circle i64 i64 i64)
  (Dot Small)
  (Empty))

(defmacro (define-big-maker [name : Expr] [bias : Expr]) : Decls
  `(begin
    (define (,name [x : i64]) : Big
      (Big (+ x ,bias) (+ x 1) (+ x 2) (+ x 3)))))

(define-big-maker generated-big 100)

(define (make-small [x : i64]) : Small
  (Small x (+ x 1)))

(define (make-big [x : i64]) : Big
  (Big x (+ x 1) (+ x 2) (+ x 3)))

(define (make-nested [x : i64]) : Nested
  (Nested (make-big x) (make-small x) x))

(define (branch-big [x : i64]) : Big
  (if (> x 3)
    (make-big x)
    (Big 0 0 0 x)))

(define (early-big [x : i64]) : Big
  (begin
    (when (> x 5) (return (Big 9 9 9 x)))
    (make-big x)))

(define (make-shape [x : i64]) : Shape
  (if (> x 0)
    (Shape.Circle x x x)
    (if (< x 0)
      (Shape.Dot (make-small x))
      (Shape.Empty))))

(define (match-big [s : Shape]) : Big
  (match s
    [(Shape.Circle r _ _) (make-big r)]
    [(Shape.Dot p) (Big p.a p.b 0 0)]
    [(Shape.Empty) (Big 0 0 0 0)]))

(define (make-tuple4 [x : i64]) : (Tuple i64 i64 i64 i64)
  (tuple x (+ x 1) (+ x 2) (+ x 3)))

(define (make-tuple2 [x : i64]) : (Tuple i64 i64)
  (tuple x (+ x 1)))

(define (make-nested-tuple [x : i64]) : (Tuple Big (Tuple i64 i64) i64)
  (tuple (make-big x) (make-tuple2 x) x))

(define (make-array4 [x : i64]) : (Array i64 4)
  (array x (+ x 1) (+ x 2) (+ x 3)))

(define (tail-big [x : i64]) : Big
  (make-big (+ x 1)))

(define (tail-tuple4 [x : i64]) : (Tuple i64 i64 i64 i64)
  (make-tuple4 (+ x 1)))

;; A MoveOnly field moves into the result place; transport neither clones the
;; String nor allocates a second owner.
(define (wrap-named [label : String] [x : i64]) : Named
  (Named label x x x))

(define (forward-named [label : String] [x : i64]) : Named
  (wrap-named label (+ x 1)))

(define (loop-carried-big [n : i64]) : Big
  (let
    [acc : Big (Big 0 0 0 0)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (make-big (+ acc.d i)))
          (set! i (+ i 1))))
      acc)))

(define (loop-carried-tuple [n : i64]) : (Tuple i64 i64 i64 i64)
  (let
    [acc : (Tuple i64 i64 i64 i64) (tuple 0 0 0 0)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (tuple
              i
              (tuple-ref acc 0)
              (tuple-ref acc 1)
              (+ (tuple-ref acc 3) i)))
          (set! i (+ i 1))))
      acc)))

;; Deep enough to overwrite any frame storage a returned value could alias.
(define (clobber [n : i64]) : i64
  (let
    [t : (Tuple i64 i64 i64 i64) (tuple n n n n)]
    [b : Big (make-big n)]
    (if (<= n 0)
      (+ (tuple-ref t 0) b.a)
      (+ (tuple-ref t 3) (clobber (- n 1))))))

(define (case-nominal) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [s : Small (make-small 1)]
    [b : Big (make-big 2)]
    [n : Nested (make-nested 3)]
    [g : Big (generated-big 4)]
    [after : i64 (profile.alloc-total)]
    (begin
      (clobber 16)
      (unless (= after before) (return 1))
      (unless (= (+ s.a s.b) 3) (return 2))
      (unless (= (+ b.a b.d) 7) (return 3))
      (unless (= (+ n.left.d (+ n.right.b n.tag)) 13) (return 4))
      (unless (= (+ g.a g.d) 111) (return 5))
      0)))

(define (case-control-flow) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [taken : Big (branch-big 4)]
    [other : Big (branch-big 1)]
    [early : Big (early-big 9)]
    [late : Big (early-big 2)]
    [tail : Big (tail-big 5)]
    [carried : Big (loop-carried-big 4)]
    [after : i64 (profile.alloc-total)]
    (begin
      (clobber 16)
      (unless (= after before) (return 11))
      (unless (= (+ taken.a other.d) 5) (return 12))
      (unless (= (+ early.a early.d) 18) (return 13))
      (unless (= (+ late.a late.d) 7) (return 14))
      (unless (= (+ tail.a tail.d) 15) (return 15))
      (unless (= carried.a 15) (return 16))
      0)))

(define (case-enum) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [circle : Big (match-big (make-shape 2))]
    [dot : Big (match-big (make-shape (- 0 2)))]
    [empty : Big (match-big (make-shape 0))]
    [after : i64 (profile.alloc-total)]
    (begin
      (clobber 16)
      (unless (= after before) (return 21))
      (unless (= (+ circle.a circle.d) 7) (return 22))
      (unless (= (+ dot.a dot.b) (- 0 3)) (return 23))
      (unless (= (+ empty.a empty.d) 0) (return 24))
      0)))

(define (case-structural) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [wide : (Tuple i64 i64 i64 i64) (make-tuple4 1)]
    [pair : (Tuple i64 i64) (make-tuple2 5)]
    [nested : (Tuple Big (Tuple i64 i64) i64) (make-nested-tuple 7)]
    [cells : (Array i64 4) (make-array4 3)]
    [tail : (Tuple i64 i64 i64 i64) (tail-tuple4 9)]
    [carried : (Tuple i64 i64 i64 i64) (loop-carried-tuple 5)]
    [after : i64 (profile.alloc-total)]
    [nested-big : Big (tuple-ref nested 0)]
    (begin
      (clobber 16)
      (unless (= after before) (return 31))
      (unless (= (+ (tuple-ref wide 0) (tuple-ref wide 3)) 5) (return 32))
      (unless (= (+ (tuple-ref pair 0) (tuple-ref pair 1)) 11) (return 33))
      (unless
        (=
          (+
            nested-big.d
            (+ (tuple-ref (tuple-ref nested 1) 1) (tuple-ref nested 2)))
          25)
        (return 34))
      (unless (= (+ (array-ref cells 0) (array-ref cells 3)) 9) (return 35))
      (unless (= (+ (tuple-ref tail 0) (tuple-ref tail 3)) 23) (return 36))
      (unless
        (= (+ (tuple-ref carried 0) (tuple-ref carried 3)) 14)
        (return 37))
      0)))

(define (case-move-only) : i64
  (let
    [first : String (string.concat "ab" "cd")]
    [second : String (string.concat "abc" "def")]
    [before : i64 (profile.alloc-total)]
    [direct : Named (wrap-named first 3)]
    [forwarded : Named (forward-named second 4)]
    [after : i64 (profile.alloc-total)]
    (begin
      (clobber 16)
      (unless (= after before) (return 41))
      (unless
        (= (+ (string.string-length direct.label) direct.pad2) 7)
        (return 42))
      (unless
        (= (+ (string.string-length forwarded.label) forwarded.pad0) 11)
        (return 43))
      0)))

(define (case-closure) : i64
  (let
    [bias : i64 30]
    [make : (-> i64 Big)
      (lambda ([x : i64]) : Big
        (Big x x x (+ x bias)))]
    [make-pair : (-> i64 (Tuple i64 i64 i64 i64))
      (lambda ([x : i64]) : (Tuple i64 i64 i64 i64)
        (tuple x x x (+ x bias)))]
    [before : i64 (profile.alloc-total)]
    [made : Big (make 2)]
    [paired : (Tuple i64 i64 i64 i64) (make-pair 3)]
    [after : i64 (profile.alloc-total)]
    (begin
      (clobber 16)
      (unless (= after before) (return 51))
      (unless (= (+ made.a made.d) 34) (return 52))
      (unless (= (+ (tuple-ref paired 0) (tuple-ref paired 3)) 36) (return 53))
      0)))

(define (main) : i64
  (let
    [nominal : i64 (case-nominal)]
    [control : i64 (case-control-flow)]
    [enums : i64 (case-enum)]
    [structural : i64 (case-structural)]
    [move-only : i64 (case-move-only)]
    [closure : i64 (case-closure)]
    (begin
      (unless (= nominal 0) (return nominal))
      (unless (= control 0) (return control))
      (unless (= enums 0) (return enums))
      (unless (= structural 0) (return structural))
      (unless (= move-only 0) (return move-only))
      (unless (= closure 0) (return closure))
      42)))