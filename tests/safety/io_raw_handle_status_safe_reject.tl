;; Bare integer handle IDs cannot bypass the validated FileHandle API.
(import stdlib.io)

(define (main) : i64
  (io.file-close-status 1))