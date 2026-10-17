(import stdlib.format)

(define (main) : i64
  (begin
    (format.ftoa-render-fixed false "123" 0 -1)
    1))