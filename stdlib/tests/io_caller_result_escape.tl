(import "stdlib/io_caller_result.tl")

; Must fail: the fallback branch is tied to `fallback`, not `outer`.
(define (main [outer : String] [path : String]) : (ReadFileOrResult outer)
  (with-arena
    inner
    (let
      [fallback : String "fallback"]
      (read-file-or-result (& path) (& fallback)))))