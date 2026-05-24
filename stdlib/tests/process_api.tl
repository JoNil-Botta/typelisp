(import "stdlib/process.tl")

(import "stdlib/test.tl")

(define (assert-process-string-list
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [message : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match rest
        [(ProcessStringCons b tail)
          (match tail
            [(ProcessStringNil)
              (begin
                (assert-string-eq a first message)
                (assert-string-eq b second message))]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-some-string
  [value : ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(ProcessSomeString actual) (assert-string-eq actual expected message)]
    [(ProcessNoString) (panic message)]))

(define (assert-process-no-string
  [value : ProcessMaybeString]
  [message : String]) : unit
  (match value
    [(ProcessNoString) unit]
    [(ProcessSomeString _) (panic message)]))

(define (assert-process-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (assert-string-eq name expected-name message)
        (assert-string-eq value expected-value message))]
    [(ProcessEnvNil) (panic message)]))

(define (assert-process-invalid-command
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (match error
        [(ProcessInvalidCommand text) (assert-string-eq text message message)]
        [_ (panic message)])]
    [(OkProcessOutput _) (panic message)]))

(define (assert-process-unsupported
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-unsupported? error) message)
        (assert-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (main) : i64
  (let ([args : ProcessStringList
    (process-args-cons "hello" (process-args-cons "world" (process-args-empty)))])
    (let ([command : ProcessCommand
      (process-command-with-env
        (process-command-with-stdin
          (process-command-with-cwd (process-command "echo" args) "target")
          "stdin")
        "TL_TEST"
        "1")])
      (begin
        (assert-string-eq
          (process-command-executable command)
          "echo"
          "process executable")
        (assert-process-string-list
          (process-command-argv command)
          "hello"
          "world"
          "process argv")
        (assert-process-some-string
          (process-command-cwd command)
          "target"
          "process cwd")
        (assert-process-some-string
          (process-command-stdin command)
          "stdin"
          "process stdin")
        (assert-process-env-head
          (process-command-env command)
          "TL_TEST"
          "1"
          "process env")
        (assert-process-no-string
          (process-command-cwd (process-command "echo" (process-args-empty)))
          "process default cwd")
        (assert-process-invalid-command
          (process-output (process-command "" (process-args-empty)))
          "process: executable path is empty")
        (assert-process-unsupported
          (process-run command)
          "process: runtime execution is not implemented")
        42))))