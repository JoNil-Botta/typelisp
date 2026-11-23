(defstruct Word
  (value i64))

(define global-word : Word
  (Word 7))

(define (replace-word [local : (& Word)] [copied : Word]) : i64
  (set! global-word (Word 9))
  (+ local.value copied.value))

(define (main) : i64
  (let
    [local : Word (Word 10)]
    (replace-word (& local) global-word)))