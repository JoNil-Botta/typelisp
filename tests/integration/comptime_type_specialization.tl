(define (id [comptime T : type] [value : T]) : T value)
(define (main) : i64 (id (type i64) 42))
