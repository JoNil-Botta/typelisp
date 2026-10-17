(import stdlib.process)

; The optional-string accessor borrows the command's field storage.
(define (main) : i64
  (let
    [command : process.ProcessCommand
      (process.command-with-cwd
        (process.command "echo" (process.args-empty))
        "cwd")]
    [cwd : (& command process.ProcessMaybeString) (process.command-cwd command)]
    [next : process.ProcessCommand (process.command-with-stdin command "input")]
    (match cwd
      [(ProcessSomeString text) (string-length text)]
      [(ProcessNoString) (process.args-count (& (process.command-argv next)))])))