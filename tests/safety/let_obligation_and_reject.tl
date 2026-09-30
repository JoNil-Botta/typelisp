;; The right operand of `and` may be skipped, so it cannot discharge alone.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(define (f [c : bool]) : i64
  (let
    [h : FileHandle (open 1)]
    (begin
      (and
        c
        (begin
          (cleanup-file-handle h)
          true))
      0)))

(define (main) : i64
  0)