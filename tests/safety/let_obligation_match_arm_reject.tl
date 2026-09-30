;; Every arm of a `match` that completes normally must discharge alike.
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

(define (f [r : Outcome]) : i64
  (let
    [h : FileHandle (open 1)]
    (match r
      [(Outcome.Ok v)
        (begin
          (cleanup-file-handle h)
          v)]
      [(Outcome.Err e) e])))

(define (main) : i64
  0)