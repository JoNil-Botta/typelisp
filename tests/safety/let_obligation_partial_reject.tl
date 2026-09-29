;; Moving one owned field out discharges only part of the aggregate.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(defstruct Pair
  (:cleanup cleanup-pair)
  (a FileHandle (:owned))
  (b i64))

(define (f) : i64
  (let
    [p : Pair (Pair (open 1) 2)]
    (begin
      (cleanup-file-handle p.a)
      0)))

(define (main) : i64
  0)