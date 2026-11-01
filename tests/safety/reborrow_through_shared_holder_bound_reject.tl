;: A reborrow of the `&mut` a holder stores, reached through a shared
;: `(& o ...)`, lives no longer than `o` either (#8449): with the stored `i`,
;: `peek` would hand out a shared view of what the holder may still write.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(define (peek [h : (& o (Holder i a))]) : (& i (RefBox a))
  (& (deref (deref h).m)))

(define (main) : i64
  42)