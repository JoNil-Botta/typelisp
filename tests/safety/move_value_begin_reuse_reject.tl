;; The last form of a `begin` initializer is moved into the binding.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (consume [h : FileHandle]) : i64
  (let
    [fd : i64 h.fd]
    (begin
      (cleanup-file-handle h)
      fd)))

(define (twice [x : FileHandle]) : i64
  (with
    ([y
        (begin
          1
          x)
        cleanup-file-handle])
    (+ y.fd (consume x))))

(define (main) : i64
  (twice (FileHandle 41)))