(import stdlib.thread)
(import (thread.handle bool) as thread_bool)

;; lint-allow: unused-import
(import stdlib.string)

(define (main) : i64
  (let
    [text : String "not-transferable"]
    (match (thread_bool.spawn
      (lambda () : bool
        (= (string-length text) 16)))
      [(thread_bool.BoolSpawnErr _) 1]
      [(thread_bool.BoolSpawnOk thread)
        (match (thread_bool.join thread)
          [(thread_bool.BoolJoinOk value)
            (if value
              42
              3)]
          [(thread_bool.BoolJoinErr _) 2])])))