;: `&mut` borrows that reach their referent only through owned storage and
;: mutable references stay accepted (#8694).
(defstruct Pt
  (name String)
  (x i64))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (bump-field [p : (&mut Pt)]) : i64
  (bump (&mut p.x))
  p.x)

(define (bump-element [items : (&mut (Slice i64))]) : i64
  (bump (&mut (array-ref items 0)))
  (array-ref items 0))

(define (main) : i64
  (let
    [n : i64 1]
    [p (Pt "a" 10)]
    [items (make-array i64 2)]
    (bump (&mut n))
    (set! (array-ref items 0) 28)
    (+ n (bump-field (&mut p)) (bump-element (&mut items)))))