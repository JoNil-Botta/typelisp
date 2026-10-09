;: `&mut` borrows that reach their referent only through owned storage and
;: mutable references stay accepted (#8694), including Box contents and private
;: buffer elements and handles reached that way (#8743).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (b (Box i64))
  (items (__tl_dyn-array i64)))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (bump-field [p : (&mut Pt)]) : i64
  (bump (&mut p.x))
  p.x)

(define (bump-element [items : (&mut (Slice i64))]) : i64
  (bump (&mut (array-ref items 0)))
  (array-ref items 0))

(define (bump-first [slot : (&mut (__tl_dyn-array i64))]) : unit
  (bump (&mut (array-ref slot 0))))

;; Box contents and buffer storage through a mutable reference to the holder.
(define (bump-holder [h : (&mut Holder)]) : i64
  (bump (&mut (deref h.b)))
  (bump (&mut (array-ref h.items 0)))
  (bump-first (&mut h.items))
  (+ (deref h.b) (array-ref h.items 0)))

(define (main) : i64
  (let
    [n : i64 1]
    [p (Pt "a" 10)]
    [items (make-array i64 2)]
    [h (Holder (box 1) (__tl_make-array i64 1))]
    (bump (&mut n))
    (set! (array-ref items 0) 28)
    ;; The same borrows through the owned holder itself.
    (bump (&mut (deref h.b)))
    (bump (&mut (array-ref h.items 0)))
    (+
      n
      (bump-field (&mut p))
      (bump-element (&mut items))
      (- (bump-holder (&mut h)) 6))))