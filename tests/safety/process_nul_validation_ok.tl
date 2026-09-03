;; Every C-string-bound command field rejects embedded NUL before the runtime
;; boundary, while length-delimited stdin preserves it.
(import stdlib.process)
(import stdlib.io)

(define (nul-text) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    (begin
      (set! (array-ref bytes 0) (cast 'a' : u8))
      (set! (array-ref bytes 1) (cast 0 : u8))
      (set! (array-ref bytes 2) (cast 'b' : u8))
      (unsafe
        (string-from-bytes (io.array-const-ptr bytes) 3)))))

(define (main) : i64
  (let
    [bad-executable : process.ProcessCommand
      (process.command (nul-text) (process.args-empty))]
    [bad-argument : process.ProcessCommand
      (process.command "echo" (process.args-single (nul-text)))]
    [bad-cwd : process.ProcessCommand
      (process.command-with-cwd
        (process.command "echo" (process.args-empty))
        (nul-text))]
    [bad-env-name : process.ProcessCommand
      (process.command-with-env
        (process.command "echo" (process.args-empty))
        (nul-text)
        "value")]
    [bad-env-value : process.ProcessCommand
      (process.command-with-env
        (process.command "echo" (process.args-empty))
        "NAME"
        (nul-text))]
    [valid-stdin : process.ProcessCommand
      (process.command-with-stdin
        (process.command "echo" (process.args-empty))
        (nul-text))]
    (if (and
      (not (process.command-valid? bad-executable))
      (not (process.command-valid? bad-argument))
      (not (process.command-valid? bad-cwd))
      (not (process.command-valid? bad-env-name))
      (not (process.command-valid? bad-env-value))
      (process.command-valid? valid-stdin))
      42
      1)))