;: A struct pattern destructures the fields in declaration order: a Copy field
;: copies, a move-only field moves into its binding.
(import stdlib.string)

(defstruct Pair
  (name String)
  (count i64))

(define (count-of [pair : Pair]) : i64
  (match pair
    [(Pair name count) (+ count (string.string-length (& name)))]))

(define (main) : i64
  (count-of (Pair (string.copy "ab") 40)))