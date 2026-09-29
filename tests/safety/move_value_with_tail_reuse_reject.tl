;; The body tail of a `with` scope is moved into the consumer like any other
;; value tail; the scope's own owner is cleaned at its exit.
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
  (let
    [first : i64
      (consume (with ([scratch (FileHandle 0) cleanup-file-handle]) x))]
    (+ first (consume x))))

(define (main) : i64
  (twice (FileHandle 21)))