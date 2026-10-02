;: A temporary that holds a cleanup-owning value without declaring a cleanup
;: function of its own cannot be cleaned after the call.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (second [pair : (& (Tuple FileHandle i64))]) : i64
  (match pair
    [(tuple _ n) n]))

(define (main) : i64
  (second (& (tuple (FileHandle 1) 2))))