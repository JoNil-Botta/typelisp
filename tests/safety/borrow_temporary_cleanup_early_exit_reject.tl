;: A later argument that can leave the call early would skip the cleanup a
;: borrowed cleanup-owning temporary is owed after the call.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (pair [h : (& FileHandle)] [n : i64]) : i64
  (+ h.fd n))

(define (main [n : i64]) : i64
  (pair
    (& (FileHandle 1))
    (if (> n 0)
      (return 0)
      n)))