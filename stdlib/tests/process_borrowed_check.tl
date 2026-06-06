(import "stdlib/process_borrowed.tl")

(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-process-string-list1
  [items : ProcessStringList]
  [first : String]
  [message : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringNil) (assert-owned-string-eq a first message)]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-some-string
  [value : ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(ProcessSomeString actual)
      (assert-owned-string-eq actual expected message)]
    [(ProcessNoString) (panic message)]))

(define (assert-process-borrowed-string-list1
  [items : (ProcessBorrowedStringList text)]
  [expected : String]
  [message : String]) : unit
  (match items
    [(ProcessBorrowedStringCons actual rest)
      (match (box-get rest)
        [(ProcessBorrowedStringNil)
          (assert-string-eq actual (& expected) message)]
        [_ (panic message)])]
    [(ProcessBorrowedStringNil) (panic message)]))

(define (assert-process-borrowed-some-string
  [value : (ProcessBorrowedMaybeString text)]
  [expected : String]
  [message : String]) : unit
  (match value
    [(ProcessBorrowedSomeString actual)
      (assert-string-eq actual (& expected) message)]
    [(ProcessBorrowedNoString) (panic message)]))

(define (assert-process-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (assert-owned-string-eq name expected-name message)
        (assert-owned-string-eq value expected-value message))]
    [(ProcessEnvNil) (panic message)]))

(define (assert-process-borrowed-env-head
  [env : (ProcessBorrowedEnvList text)]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match env
    [(ProcessBorrowedEnvCons name value _)
      (begin
        (assert-string-eq name (& expected-name) message)
        (assert-string-eq value (& expected-value) message))]
    [(ProcessBorrowedEnvNil) (panic message)]))

(define (assert-process-invalid-command
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-invalid-command? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (assert-process-child-invalid-command
  [result : ResultProcessChild]
  [message : String]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true (process-error-invalid-command? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessChild _) (panic message)]))

(define (process-borrowed-api-check) : unit
  (let
    [exe : String "echo"]
    [arg : String "hello"]
    [cwd : String "target"]
    [env-pair : String "TL_BORROWED_PROCESS"]
    [stdin : String "stdin"]
    [argv : (ProcessBorrowedStringList arg)
      (process-borrowed-args-single (& arg))]
    [env : (ProcessBorrowedEnvList env-pair)
      (process-borrowed-env-cons
        (& env-pair)
        (& env-pair)
        (process-borrowed-env-empty-like (& env-pair)))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (process-borrowed-command-empty (& exe))]
    [with-argv : (ProcessBorrowedCommand exe arg exe exe exe)
      (process-borrowed-command-with-argv base argv)]
    [with-cwd : (ProcessBorrowedCommand exe arg cwd exe exe)
      (process-borrowed-command-with-cwd with-argv (& cwd))]
    [with-env-list : (ProcessBorrowedCommand exe arg cwd env-pair exe)
      (process-borrowed-command-with-env-list with-cwd env)]
    [borrowed : (ProcessBorrowedCommand exe arg cwd env-pair stdin)
      (process-borrowed-command-with-stdin with-env-list (& stdin))]
    [owned : ProcessCommand (process-borrowed-command-owned borrowed)]
    (begin
      (assert-string-eq
        (process-borrowed-command-executable borrowed)
        (& exe)
        "borrowed process executable")
      (assert-process-borrowed-string-list1
        (process-borrowed-command-argv borrowed)
        "hello"
        "borrowed process argv")
      (assert-i64-eq
        (process-borrowed-args-count (process-borrowed-command-argv borrowed))
        1
        "borrowed process argv count")
      (assert-process-borrowed-some-string
        (process-borrowed-command-cwd borrowed)
        "target"
        "borrowed process cwd")
      (assert-process-borrowed-some-string
        (process-borrowed-command-stdin borrowed)
        "stdin"
        "borrowed process stdin")
      (assert-process-borrowed-env-head
        (process-borrowed-command-env borrowed)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS"
        "borrowed process env")
      (assert-i64-eq
        (process-borrowed-env-count (process-borrowed-command-env borrowed))
        1
        "borrowed process env count")
      (assert-owned-string-eq
        (process-command-executable owned)
        "echo"
        "borrowed process owned executable")
      (assert-process-string-list1
        (process-command-argv owned)
        "hello"
        "borrowed process owned argv")
      (assert-process-some-string
        (process-command-cwd owned)
        "target"
        "borrowed process owned cwd")
      (assert-process-some-string
        (process-command-stdin owned)
        "stdin"
        "borrowed process owned stdin")
      (assert-process-env-head
        (process-command-env owned)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS"
        "borrowed process owned env")
      (assert-true
        (process-borrowed-command-valid? borrowed)
        "borrowed process valid command"))))

(define (process-borrowed-validation-check) : unit
  (let
    [exe : String "echo"]
    [empty : String ""]
    [bad-env-name : String "BAD=NAME"]
    [empty-command : (ProcessBorrowedCommand empty empty empty empty empty)
      (process-borrowed-command-empty (& empty))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (process-borrowed-command-empty (& exe))]
    [empty-cwd-command : (ProcessBorrowedCommand exe exe empty exe exe)
      (process-borrowed-command-with-cwd base (& empty))]
    [empty-env-command : (ProcessBorrowedCommand exe exe exe empty exe)
      (process-borrowed-command-with-env-list
        base
        (process-borrowed-env-cons
          (& empty)
          (& empty)
          (process-borrowed-env-empty-like (& empty))))]
    [bad-env-command : (ProcessBorrowedCommand exe exe exe bad-env-name exe)
      (process-borrowed-command-with-env-list
        base
        (process-borrowed-env-cons
          (& bad-env-name)
          (& bad-env-name)
          (process-borrowed-env-empty-like (& bad-env-name))))]
    (begin
      (assert-process-invalid-command
        (process-borrowed-output empty-command)
        "process: executable path is empty")
      (assert-process-child-invalid-command
        (process-borrowed-start empty-command)
        "process: executable path is empty")
      (assert-process-invalid-command
        (process-borrowed-output empty-cwd-command)
        "process: cwd path is empty")
      (assert-process-invalid-command
        (process-borrowed-output empty-env-command)
        "process: environment variable name is empty")
      (assert-process-invalid-command
        (process-borrowed-output bad-env-command)
        "process: environment variable name contains '='")
      (assert-false
        (process-borrowed-command-valid? empty-command)
        "borrowed process invalid empty executable"))))

(define (main) : unit
  (begin
    (process-borrowed-api-check)
    (process-borrowed-validation-check)))