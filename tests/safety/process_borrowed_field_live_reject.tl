(import stdlib.process_borrowed as process)

; A field accessor borrows the list storage as well as its external text.
(define (main) : i64
  (let
    [text : String "echo"]
    [command : (process.ProcessBorrowedCommand text text text text text)
      (process.command-empty (& text))]
    [args : (& command (process.ProcessBorrowedStringList text))
      (process.command-argv command)]
    [next : (process.ProcessBorrowedCommand text text text text text)
      (process.command-with-cwd command (& text))]
    (+
      (process.args-count args)
      (string-length (process.command-executable next)))))