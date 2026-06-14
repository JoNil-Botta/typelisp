(import "stdlib/thread.tl")

(define (main) : i64
  (unsafe
    (let
      [ptr : (Ptr i64) (int->ptr (cast 0 : u64) : (Ptr i64))]
      (match (thread-spawn-i64
        (lambda () : i64
          (if (= (ptr->int ptr) (cast 0 : u64))
            1
            2)))
        [(ThreadI64SpawnErr _) 3]
        [(ThreadI64SpawnOk thread)
          (match (thread-join-i64 thread)
            [(ThreadI64JoinOk value) value]
            [(ThreadI64JoinErr _) 4])]))))