;; A `break` leaves the scope of an owner bound inside the loop.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(define (f [n : i64]) : i64
  (begin
    (while (< n 3)
      (let
        [h : FileHandle (open n)]
        (break)))
    0))

(define (main) : i64
  0)