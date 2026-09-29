;; Discharging on only one arm of an `if` is rejected at the join.
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
      (if c
        (cleanup-file-handle h)
        unit)
      0)))

(define (main) : i64
  0)