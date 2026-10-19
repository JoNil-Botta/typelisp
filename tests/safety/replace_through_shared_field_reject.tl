;; A `&mut` field of a struct reached through a shared reference grants only
;; shared access (Rust E0594): replace! cannot write its referent.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (:lifetimes a)
  (r (&mut a Pt))
  (n i64))

(define (sneak [h : (& h (Holder a))]) : Pt
  (replace! (deref (deref h).r) (Pt "z" 2)))

(define (main) : i64
  42)