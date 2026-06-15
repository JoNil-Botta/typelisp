(import stdlib.io_caller_result)

(define (read-or-result [path : (& path str)] [fallback : (& fallback str)]) : (io_caller_result.ReadFileOrResult
    fallback)
  (io_caller_result.read-file-or-result path fallback))

(define (read-or-result-with-local-path [fallback : (& fallback str)]) : (io_caller_result.ReadFileOrResult
    fallback)
  (let
    [path : String "target/stdlib-verify/io_caller_result_missing.txt"]
    (io_caller_result.read-file-or-result (& path) fallback)))

(define (consume-read-file-or-result [result : (io_caller_result.ReadFileOrResult fallback)]) : String
  (io_caller_result.read-file-or-result-string result))

(define (main [path : String] [fallback : String]) : unit
  (let
    [direct : (io_caller_result.ReadFileOrResult fallback)
      (read-or-result (& path) (& fallback))]
    [local-path : (io_caller_result.ReadFileOrResult fallback)
      (read-or-result-with-local-path (& fallback))]
    [direct-owned : String (consume-read-file-or-result direct)]
    [local-owned : String (consume-read-file-or-result local-path)]
    [direct-borrowed : bool (io_caller_result.read-file-or-result-borrowed? direct)]
    [local-owned? : bool (io_caller_result.read-file-or-result-owned? local-path)]
    unit))