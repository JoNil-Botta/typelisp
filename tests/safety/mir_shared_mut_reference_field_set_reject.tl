;: A field write through a `&mut` reached through a `&` is a write through a
;: shared reference (Rust E0594, #8449).
(defstruct P
  (a i64))

(define (poke [r : (& o (&mut i P))]) : unit
  (set! (deref (deref r)).a 5))

(define (main) : i64
  42)