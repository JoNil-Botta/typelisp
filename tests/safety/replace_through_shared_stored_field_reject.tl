;; A `&mut` field named through a shared reference parameter (`h.r`) grants
;; only shared access (Rust E0594): replace! cannot write a field of its
;; referent.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (:lifetimes a)
  (r (&mut a Pt))
  (n i64))

(define (sneak [h : (& h (Holder a))]) : String
  (replace! (deref h.r).name "z"))

(define (main) : i64
  42)