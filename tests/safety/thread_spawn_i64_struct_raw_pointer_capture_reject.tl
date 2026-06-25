(import "stdlib/thread.tl")
(import (thread-handle i64) as thread_i64)

(defstruct RawPointerHolder
  (ptr (Ptr i64)))

(define (main) : i64
  (unsafe
    (let
      [holder : RawPointerHolder
        (RawPointerHolder (int->ptr (cast 0 : u64) : (Ptr i64)))]
      (match (thread_i64.spawn
        (lambda () : i64
          (if (= (ptr->int (struct-get holder ptr)) (cast 0 : u64))
            1
            2)))
        [(thread_i64.I64SpawnErr _) 3]
        [(thread_i64.I64SpawnOk thread)
          (match (thread_i64.join thread)
            [(thread_i64.I64JoinOk value) value]
            [(thread_i64.I64JoinErr _) 4])]))))