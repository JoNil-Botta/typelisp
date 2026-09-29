;; The body of a `let` whose value is consumed moves the outer variable it names.
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
  (+
    (consume
      (let
        [k : i64 1]
        x))
    (consume x)))

(define (main) : i64
  (twice (FileHandle 41)))