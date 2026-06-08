(extern (tl_alloc [arg0 : u64]) : u64)

;; Cast -1 to u64 to get the max value (0xFFFFFFFFFFFFFFFF) so tl_alloc fails.
(define (main) : u64
  (tl_alloc (cast -1 : u64)))