;: As `mir_shared_mut_reference_push_reject`, with the `&mut` in a field read
;: through the shared reference (#8449).
(defstruct Holder
  (:lifetimes i)
  (m (&mut i (__tl_dyn-array i64))))

(define (grow [h : (& o (Holder i))]) : unit
  (__tl_array-push! (deref (deref h).m) 9))

(define (main) : i64
  42)