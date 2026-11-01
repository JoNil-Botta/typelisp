;; #9096's witness: a holder's `&mut` field named through a shared reference
;; to the holder (`h.r`) grants only shared access, so `set!` of its referent
;; is a write through a shared reference (Rust E0594). Main 8d29b08a1, before
;; the typed ownership IR (#8889), accepted it.
(defstruct Pt
  (s String)
  (x i64))

(defstruct Hold
  (:lifetimes a)
  (r (&mut a Pt)))

(define (sneak [h : (& h (Hold a))]) : unit
  (set! (deref h.r) (Pt "z" 42)))

(define (main) : i64
  42)