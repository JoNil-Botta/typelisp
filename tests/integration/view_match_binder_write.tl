;; A binding of a match on a view read through `&mut` references only is a
;; mutable view of its part: it shares the referent's storage, so every write
;; through it (a field, box contents, `replace!`, a `&mut` loan, through a
;; matched view binder, a binding of a binding, an or-pattern, several
;; payloads, in a loop) lands in the caller's value.
(import stdlib.string)

(defstruct In
  (b (Box String))
  (n i64))

(defenum Shape
  (Filled In)
  (Pair In i64)
  (Spare In)
  (Empty i64))

(defenum Nest
  (Wrap Shape)
  (Bare))

(defstruct Out
  (s Shape)
  (q Shape)
  (r Shape)
  (w Nest)
  (t i64))

(define (bump-in [q : (&mut q In)]) : unit
  (set! q.n (+ q.n 1)))

(define (write-direct [p : (&mut p Out)]) : i64
  (match p.s
    [(Shape.Filled x)
      (set! (deref x.b) "first")
      (set! x.n 10)
      (bump-in (&mut x))
      (let
        [old : (Box String) (replace! x.b (box "second"))]
        (string.string-length (& (deref old))))]
    [_ 0]))

(define (write-through-view [p : (&mut p Out)]) : unit
  (let
    [v p.q]
    (match v
      [(Shape.Pair x k)
        (set! x.n (+ x.n k))
        (let
          [_old (replace! (deref x.b) "pair")]
          unit)]
      [_ unit])))

(define (write-alternatives [p : (&mut p Out)]) : unit
  (match p.r
    [(or (Shape.Filled x) (Shape.Spare x)) (set! x.n (+ x.n 30))]
    [_ unit]))

(define (write-nested [p : (&mut p Out)]) : unit
  (match p.w
    [(Nest.Wrap g)
      (match g
        [(Shape.Filled x) (set! x.n (+ x.n 40))]
        [_ unit])]
    [Nest.Bare unit]))

(define (write-loop [p : (&mut p Out)] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (match p.s
        [(Shape.Filled x) (set! x.n (+ x.n 1))]
        [_ unit])
      (set! index (+ index 1)))))

(define (n-of [shape : (& shape Shape)]) : i64
  (match shape
    [(Shape.Filled x) x.n]
    [(Shape.Pair x _) x.n]
    [(Shape.Spare x) x.n]
    [(Shape.Empty k) k]))

(define (text-of [shape : (& shape Shape)]) : String
  (match shape
    [(Shape.Filled x) (clone (deref x.b))]
    [(Shape.Pair x _) (clone (deref x.b))]
    [(Shape.Spare x) (clone (deref x.b))]
    [(Shape.Empty _) ""]))

(define (main) : i64
  (let
    [o : Out
      (Out
        (Shape.Filled (In (box "a") 1))
        (Shape.Pair (In (box "b") 2) 7)
        (Shape.Spare (In (box "c") 3))
        (Nest.Wrap (Shape.Filled (In (box "d") 4)))
        5)]
    [old-length : i64 (write-direct (&mut o))]
    [_view : unit (write-through-view (&mut o))]
    [_alternatives : unit (write-alternatives (&mut o))]
    [_nested : unit (write-nested (&mut o))]
    [_loop : unit (write-loop (&mut o) 3)]
    (if (and
      (= old-length 5)
      (= (n-of (& o.s)) 14)
      (string.eq (text-of (& o.s)) "second")
      (= (n-of (& o.q)) 9)
      (string.eq (text-of (& o.q)) "pair")
      (= (n-of (& o.r)) 33)
      (match o.w
        [(Nest.Wrap g) (= (n-of g) 44)]
        [Nest.Bare false]))
      42
      1)))