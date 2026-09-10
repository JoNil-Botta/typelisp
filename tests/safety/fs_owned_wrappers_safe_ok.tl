;; Public filesystem operations retain safe signatures because they own their
;; host buffers and validate host status before interpreting them.
(import stdlib.fs)
(import stdlib.string)

(define (owned-wrappers [path : (& path str)]) : i64
  (begin
    (fs.read-dir-status (string.copy path))
    (fs.file-size-status path)
    (fs.file-kind-status path)))

(define (main) : i64
  0)