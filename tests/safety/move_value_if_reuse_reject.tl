;; A variable in an `if` arm is moved with the `if`'s consumed value.
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

(define (pick [c : bool] [x : FileHandle] [z : FileHandle]) : i64
  (+
    (consume
      (if c
        x
        z))
    (consume x)))

(define (main) : i64
  (pick true (FileHandle 41) (FileHandle 1)))