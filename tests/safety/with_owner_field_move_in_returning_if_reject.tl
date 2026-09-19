(define (close-fd [fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (steal [h : FileHandle]) : i64
  (with ([owned h cleanup-file-handle]) owned.fd))

(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))

(define (pick [flag : bool]) : i64
  (with
    ([h (Holder (FileHandle 3) 7) cleanup-holder])
    (begin
      (if flag
        (return (steal h.handle))
        unit)
      7)))

(define (main) : i64
  (pick false))