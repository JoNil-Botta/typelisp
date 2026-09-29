;; Moving a `with` owner through a consumed `begin` value is seen by the owner's
;; exit check, so the owner is not cleaned a second time.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (take [h : FileHandle]) : unit
  (cleanup-file-handle h))

(define (run) : i64
  (with
    ([h (FileHandle 7) cleanup-file-handle])
    (begin
      (take
        (begin
          0
          h))
      0)))

(define (main) : i64
  (begin
    (run)
    closes))