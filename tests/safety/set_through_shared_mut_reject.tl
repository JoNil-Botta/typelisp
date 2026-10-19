;; A `&mut` stored in a tuple behind a shared reference grants only shared
;; access: `set!` of its referent is the `&mut` borrow rule's violation, as a
;; `replace!` or a `&mut` reborrow of it is.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (Tuple (&mut a Pt) i64))]) : unit
  (set! (deref (tuple-ref (deref h) 0)) (Pt "z" 2)))

(define (main) : i64
  42)