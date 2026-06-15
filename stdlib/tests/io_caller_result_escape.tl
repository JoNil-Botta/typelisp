(import stdlib.io_caller_result)

; Must fail: the fallback branch is tied to `fallback`, not `outer`.
(define (main [outer : String] [path : String]) : (io_caller_result.ReadFileOrResult outer)
  (with-arena
    inner
    (let
      [fallback : String "fallback"]
      (io_caller_result.read-file-or-result (& path) (& fallback)))))