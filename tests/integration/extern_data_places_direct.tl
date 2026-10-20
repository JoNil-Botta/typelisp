(extern foreign-word (:symbol "tl-data-word") : i64)
(extern plain : i64)

(define (main) : i64
  (set! foreign-word 40)
  (set! plain 19)
  (+
    (unsafe
      (ptr-read (ptr-addr-of foreign-word)))
    (- plain 17)))