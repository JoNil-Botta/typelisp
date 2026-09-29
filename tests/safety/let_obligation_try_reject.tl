;; A `try` that can propagate an error leaves the owner undischarged.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(defenum Outcome
  (Ok i64)
  (Err i64))

(define (fail) : Outcome
  (Outcome.Err 1))

(define (f) : Outcome
  (let
    [h : FileHandle (open 1)]
    (let
      [v : i64 (try (fail))]
      (begin
        (cleanup-file-handle h)
        (Outcome.Ok v)))))

(define (main) : i64
  0)