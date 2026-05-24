;; stdlib/process.tl - Process command API surface for TypeLisp (#840).

;;

;; This module defines the canonical process command/output/error data model for

;; selfhost tools. Runtime process execution is intentionally not implemented

;; yet: process-run/process-output return structured errors instead of routing

;; through Rust host actions or shell-tokenized command strings.

;;

;; Usage: (import "stdlib/process.tl")

(defenum ProcessStringList
  (ProcessStringNil)
  (ProcessStringCons String ProcessStringList))

(defenum ProcessMaybeString
  (ProcessNoString)
  (ProcessSomeString String))

(defenum ProcessEnvList
  (ProcessEnvNil)
  (ProcessEnvCons String String ProcessEnvList))

(defstruct ProcessCommand
  (executable String)
  (argv ProcessStringList)
  (cwd ProcessMaybeString)
  (env ProcessEnvList)
  (stdin ProcessMaybeString))

(defstruct ProcessOutput
  (status i64)
  (stdout String)
  (stderr String))

(defenum ProcessError
  (ProcessInvalidCommand String)
  (ProcessSpawnFailed String)
  (ProcessWaitFailed String)
  (ProcessUnsupported String))

(defenum ResultProcessOutput
  (OkProcessOutput ProcessOutput)
  (ErrProcessOutput ProcessError))

(define (process-args-empty) : ProcessStringList
  (ProcessStringNil))

(define (process-args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (ProcessStringCons value rest))

(define (process-env-empty) : ProcessEnvList
  (ProcessEnvNil))

(define (process-env-cons
  [name : String]
  [value : String]
  [rest : ProcessEnvList]) : ProcessEnvList
  (ProcessEnvCons name value rest))

(define (process-no-stdin) : ProcessMaybeString
  (ProcessNoString))

(define (process-stdin-string [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

(define (process-no-cwd) : ProcessMaybeString
  (ProcessNoString))

(define (process-cwd [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

(define (process-command [executable : String] [argv : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    executable
    argv
    (ProcessNoString)
    (ProcessEnvNil)
    (ProcessNoString)))

(define (process-command-full
  [executable : String]
  [argv : ProcessStringList]
  [cwd : ProcessMaybeString]
  [env : ProcessEnvList]
  [stdin : ProcessMaybeString]) : ProcessCommand
  (ProcessCommand executable argv cwd env stdin))

(define (process-command-with-cwd [command : ProcessCommand] [cwd : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (ProcessSomeString cwd)
    (process-command-env command)
    (process-command-stdin command)))

(define (process-command-with-env
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (ProcessEnvCons name value (process-command-env command))
    (process-command-stdin command)))

(define (process-command-with-stdin [command : ProcessCommand] [stdin : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (process-command-env command)
    (ProcessSomeString stdin)))

(define (process-command-executable [command : ProcessCommand]) : String
  (struct-get command executable))

(define (process-command-argv [command : ProcessCommand]) : ProcessStringList
  (struct-get command argv))

(define (process-command-cwd [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command cwd))

(define (process-command-env [command : ProcessCommand]) : ProcessEnvList
  (struct-get command env))

(define (process-command-stdin [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command stdin))

(define (process-output-status [output : ProcessOutput]) : i64
  (struct-get output status))

(define (process-output-stdout [output : ProcessOutput]) : String
  (struct-get output stdout))

(define (process-output-stderr [output : ProcessOutput]) : String
  (struct-get output stderr))

(define (process-success? [output : ProcessOutput]) : bool
  (= (process-output-status output) 0))

(define (process-error-message [error : ProcessError]) : String
  (match error
    [(ProcessInvalidCommand message) message]
    [(ProcessSpawnFailed message) message]
    [(ProcessWaitFailed message) message]
    [(ProcessUnsupported message) message]))

(define (process-error-unsupported? [error : ProcessError]) : bool
  (match error
    [(ProcessUnsupported _) true]
    [_ false]))

(define (process-output [command : ProcessCommand]) : ResultProcessOutput
  (if (string-eq (process-command-executable command) "")
    (ErrProcessOutput
      (ProcessInvalidCommand "process: executable path is empty"))
    (ErrProcessOutput
      (ProcessUnsupported "process: runtime execution is not implemented"))))

(define (process-run [command : ProcessCommand]) : ResultProcessOutput
  (process-output command))