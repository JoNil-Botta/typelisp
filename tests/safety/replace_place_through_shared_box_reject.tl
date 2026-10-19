;: A Box owns its payload, so a `&mut` inside a Box behind a shared
;: reference is still reached through that shared reference (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& (Box (Tuple (&mut Pt) i64)))]) : Pt
  (replace! (deref (tuple-ref (deref (deref h)) 0)) (Pt "z" 2)))

(define (main) : i64
  42)