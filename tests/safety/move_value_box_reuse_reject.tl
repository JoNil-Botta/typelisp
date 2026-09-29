;; A box holding a cleanup-owning value is moved through an `if` arm.
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

(define (consume-box [b : (Box FileHandle)]) : i64
  (consume (deref b)))

(define (twice [c : bool] [x : (Box FileHandle)] [z : (Box FileHandle)]) : i64
  (+
    (consume-box
      (if c
        x
        z))
    (consume-box x)))

(define (main) : i64
  (twice true (box (FileHandle 41)) (box (FileHandle 1))))