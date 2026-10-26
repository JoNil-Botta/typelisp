;; A cleanup owner lent to a C function pointer value stays the caller's: its
;; obligation must still be discharged before its scope ends.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (lend-only [callback : (CFunc non-null (-> Handle i64))]) : i64
  (let
    [h : Handle (Handle 1)]
    (callback h)))

(define (main) : i64
  0)