;; The bootstrap mutation gate rewrites the `when` transformer's zero-body
;; sentinel in an isolated stdlib tree. Both the source and newly embedded
;; native routes must surface that changed expansion here.
(define (main) : i64
  (begin
    (when true)
    42))