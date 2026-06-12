(import "stdlib/io_caller_result.tl")

(define (read-or-result [path : (& path str)] [fallback : (& fallback str)]) : (ReadFileOrResult
    fallback)
  (read-file-or-result path fallback))

(define (read-or-result-with-local-path [fallback : (& fallback str)]) : (ReadFileOrResult
    fallback)
  (let
    [path : String "target/stdlib-verify/io_caller_result_missing.txt"]
    (read-file-or-result (& path) fallback)))

(define (consume-read-file-or-result [result : (ReadFileOrResult fallback)]) : String
  (read-file-or-result-string result))

(define (main [path : String] [fallback : String]) : unit
  (let
    [direct : (ReadFileOrResult fallback)
      (read-or-result (& path) (& fallback))]
    [local-path : (ReadFileOrResult fallback)
      (read-or-result-with-local-path (& fallback))]
    [direct-owned : String (consume-read-file-or-result direct)]
    [local-owned : String (consume-read-file-or-result local-path)]
    [direct-borrowed : bool (read-file-or-result-borrowed? direct)]
    [local-owned? : bool (read-file-or-result-owned? local-path)]
    unit))