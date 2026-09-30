;; An early `return` leaves the `let` scope with the owner undischarged.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(define (f [failed : bool]) : i64
  (let
    [h : FileHandle (open 1)]
    (begin
      (if failed
        (return -1)
        unit)
      (cleanup-file-handle h)
      0)))

(define (main) : i64
  0)