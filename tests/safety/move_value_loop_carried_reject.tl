;; A loop-carried owner cannot be moved through a consumed `begin` value.
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

(define (repeat [x : FileHandle] [n : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (< total n)
        (set!
          total
          (+
            total
            (consume
              (begin
                0
                x)))))
      total)))

(define (main) : i64
  (repeat (FileHandle 1) 3))