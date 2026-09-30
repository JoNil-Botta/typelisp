;; An outer owner discharged only on a `break` path is still owned on the zero-trip path.
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
  (let
    [h : FileHandle (open 1)]
    (begin
      (while (< n 3)
        (begin
          (cleanup-file-handle h)
          (break)))
      0)))

(define (main) : i64
  0)