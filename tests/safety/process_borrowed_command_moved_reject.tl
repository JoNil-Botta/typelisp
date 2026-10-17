(import stdlib.process_borrowed as process)

; Builders consume the command even though the text it refers to stays live.
(define (main) : i64
  (let
    [text : String "echo"]
    [command : (process.ProcessBorrowedCommand text text text text text)
      (process.command-empty (& text))]
    [next : (process.ProcessBorrowedCommand text text text text text)
      (process.command-with-cwd command (& text))]
    (+
      (string-length (process.command-executable command))
      (string-length (process.command-executable next)))))