;# Process command API surface for TypeLisp (#840).
;#
;# Defines the canonical process command/output/error data model for selfhost
;# tools. Runtime process execution is provided by the backend-emitted
;# `tl_process_output`, `tl_process_start`, and `tl_process_wait` helpers;
;# unsupported target/runtime combinations return structured errors instead of
;# routing through Rust host actions or shell-tokenized command strings.
;# Linux execution preserves inherited environment entries except names
;# provided by `ProcessEnvList`, which are replaced by the override value.
;#
;# Usage: `(import "stdlib/process.tl")`
;#
;: Immutable list of process argument strings in argv order.
(defenum ProcessStringList
  (ProcessStringNil)
  (ProcessStringCons String (Box ProcessStringList)))

;: Optional string value used for cwd and stdin configuration.
(defenum ProcessMaybeString
  (ProcessNoString)
  (ProcessSomeString String))

;: Environment override list stored as name/value pairs.
(defenum ProcessEnvList
  (ProcessEnvNil)
  (ProcessEnvCons String String (Box ProcessEnvList)))

;: Process command data: executable path, argv, cwd, env, and stdin.
(defstruct ProcessCommand
  (executable String)
  (argv ProcessStringList)
  (cwd ProcessMaybeString)
  (env ProcessEnvList)
  (stdin ProcessMaybeString))

;: Captured process result data.
(defstruct ProcessOutput
  (status i64)
  (stdout String)
  (stderr String))

;: Runtime-owned asynchronous process handle data.
;:
;: The integer fields are opaque runtime handles. Callers should pass the value
;: to `process-wait` rather than inspecting or constructing handles directly.
(defstruct ProcessChild
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64))

;: Structured process failures returned instead of host-action panics.
(defenum ProcessError
  (ProcessInvalidCommand String)
  (ProcessSpawnFailed String)
  (ProcessWaitFailed String)
  (ProcessUnsupported String))

;: Result type for process execution APIs.
(defenum ResultProcessOutput
  (OkProcessOutput ProcessOutput)
  (ErrProcessOutput ProcessError))

;: Result type for asynchronous process start APIs.
(defenum ResultProcessChild
  (OkProcessChild ProcessChild)
  (ErrProcessChild ProcessError))

;: Backend runtime hook used by `process-output`.
;:
;: The public wrapper performs TypeLisp-side validation first. The runtime
;: helper receives structured command data and returns the same concrete result
;: model.
(extern tl_process_output : (-> ProcessCommand ResultProcessOutput))

;: Backend runtime hook used by `process-start`.
(extern tl_process_start : (-> ProcessCommand ResultProcessChild))

;: Backend runtime hook used by `process-wait`.
(extern tl_process_wait : (-> ProcessChild ResultProcessOutput))

;: Return an empty argument list.
(define (process-args-empty) : ProcessStringList
  (ProcessStringNil))

;: Return the number of argv entries in `args`.
(define (process-args-count [args : ProcessStringList]) : i64
  (match args
    [(ProcessStringNil) 0]
    [(ProcessStringCons _ rest) (+ 1 (process-args-count (box-get rest)))]))

;: Prepend an owned argument string to an argv list.
(define (process-args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (ProcessStringCons value (box rest)))

;: Return a one-element argument list backed by an owned string.
(define (process-args-single [value : String]) : ProcessStringList
  (ProcessStringCons value (box (ProcessStringNil))))

;: Concatenate two argument lists while preserving argv order.
(define (process-args-append
  [left : ProcessStringList]
  [right : ProcessStringList]) : ProcessStringList
  (match left
    [(ProcessStringNil) right]
    [(ProcessStringCons value rest)
      (ProcessStringCons value (box (process-args-append (box-get rest) right)))]))

;: Return an empty environment override list.
(define (process-env-empty) : ProcessEnvList
  (ProcessEnvNil))

;: Return the number of env overrides in `env`.
(define (process-env-count [env : ProcessEnvList]) : i64
  (match env
    [(ProcessEnvNil) 0]
    [(ProcessEnvCons _ _ rest) (+ 1 (process-env-count (box-get rest)))]))

;: Prepend owned environment override strings to an env list.
(define (process-env-cons
  [name : String]
  [value : String]
  [rest : ProcessEnvList]) : ProcessEnvList
  (ProcessEnvCons name value (box rest)))

;: Return true when `text` contains `needle`.
(define (process-string-contains-char? [text : (& text str)] [needle : char]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (= (string-ref text i) needle)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

;: Return a command stdin value that provides no input.
(define (process-no-stdin) : ProcessMaybeString
  (ProcessNoString))

;: Return a command stdin value backed by an owned string.
(define (process-stdin-string [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Return a cwd value that inherits the current working directory.
(define (process-no-cwd) : ProcessMaybeString
  (ProcessNoString))

;: Return a cwd value that runs the command under an owned path string.
(define (process-cwd [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Construct a process command with owned executable storage and default cwd,
;: env, and stdin settings.
(define (process-command [executable : String] [argv : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    executable
    argv
    (ProcessNoString)
    (ProcessEnvNil)
    (ProcessNoString)))

;: Return a copy of `command` with `arg` appended after existing argv entries.
(define (process-command-with-arg [command : ProcessCommand] [arg : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-append
      (process-command-argv command)
      (process-args-single arg))
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with `args` appended after existing argv entries.
(define (process-command-with-args
  [command : ProcessCommand]
  [args : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-append (process-command-argv command) args)
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Construct a process command with every owned-storage field supplied
;: explicitly.
(define (process-command-full
  [executable : String]
  [argv : ProcessStringList]
  [cwd : ProcessMaybeString]
  [env : ProcessEnvList]
  [stdin : ProcessMaybeString]) : ProcessCommand
  (ProcessCommand executable argv cwd env stdin))

;: Return a copy of `command` with cwd set to `cwd`.
(define (process-command-with-cwd [command : ProcessCommand] [cwd : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (ProcessSomeString cwd)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with an additional env override.
(define (process-command-with-env
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (ProcessEnvCons name value (box (process-command-env command)))
    (process-command-stdin command)))

;: Return a copy of `command` with the full env override list replaced.
(define (process-command-with-env-list
  [command : ProcessCommand]
  [env : ProcessEnvList]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    env
    (process-command-stdin command)))

;: Return a copy of `command` with stdin set to `stdin`.
(define (process-command-with-stdin [command : ProcessCommand] [stdin : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (process-command-env command)
    (ProcessSomeString stdin)))

;: Return the executable path from `command`.
(define (process-command-executable [command : ProcessCommand]) : String
  (struct-get command executable))

;: Return the argv list from `command`.
(define (process-command-argv [command : ProcessCommand]) : ProcessStringList
  (struct-get command argv))

;: Return the cwd setting from `command`.
(define (process-command-cwd [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command cwd))

;: Return the env override list from `command`.
(define (process-command-env [command : ProcessCommand]) : ProcessEnvList
  (struct-get command env))

;: Return the stdin setting from `command`.
(define (process-command-stdin [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command stdin))

;: Return the process exit status.
(define (process-output-status [output : ProcessOutput]) : i64
  (struct-get output status))

;: Return captured stdout from `output`.
(define (process-output-stdout [output : ProcessOutput]) : String
  (struct-get output stdout))

;: Return captured stderr from `output`.
(define (process-output-stderr [output : ProcessOutput]) : String
  (struct-get output stderr))

;: Return true when the process exit status is zero.
(define (process-success? [output : ProcessOutput]) : bool
  (= (process-output-status output) 0))

;: Return true when `result` is a successful zero-exit process output.
(define (process-result-success? [result : ResultProcessOutput]) : bool
  (match result
    [(OkProcessOutput output) (process-success? output)]
    [(ErrProcessOutput _) false]))

;: Return true when `result` is a started child handle.
(define (process-child-started? [result : ResultProcessChild]) : bool
  (match result
    [(OkProcessChild _) true]
    [(ErrProcessChild _) false]))

;: Return the diagnostic message stored in `error`.
(define (process-error-message [error : ProcessError]) : String
  (match error
    [(ProcessInvalidCommand message) message]
    [(ProcessSpawnFailed message) message]
    [(ProcessWaitFailed message) message]
    [(ProcessUnsupported message) message]))

;: Return true when `error` is a command validation diagnostic.
(define (process-error-invalid-command? [error : ProcessError]) : bool
  (match error
    [(ProcessInvalidCommand _) true]
    [_ false]))

;: Return true when `error` is a spawn failure diagnostic.
(define (process-error-spawn-failed? [error : ProcessError]) : bool
  (match error
    [(ProcessSpawnFailed _) true]
    [_ false]))

;: Return true when `error` is a wait failure diagnostic.
(define (process-error-wait-failed? [error : ProcessError]) : bool
  (match error
    [(ProcessWaitFailed _) true]
    [_ false]))

;: Return true when `error` is an unsupported runtime/platform diagnostic.
(define (process-error-unsupported? [error : ProcessError]) : bool
  (match error
    [(ProcessUnsupported _) true]
    [_ false]))

;: Return the first env validation error, or `ProcessNoString`.
(define (process-env-validation-error [env : ProcessEnvList]) : ProcessMaybeString
  (match env
    [(ProcessEnvNil) (ProcessNoString)]
    [(ProcessEnvCons name _ rest)
      (if (string-eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (let
          [text : String name]
          (if (process-string-contains-char? (& text) #=')
            (ProcessSomeString
              "process: environment variable name contains '='")
            (process-env-validation-error (box-get rest)))))]))

;: Return the first command validation error, or `ProcessNoString`.
(define (process-command-validation-error [command : ProcessCommand]) : ProcessMaybeString
  (if (string-eq (process-command-executable command) "")
    (ProcessSomeString "process: executable path is empty")
    (match (process-command-cwd command)
      [(ProcessSomeString cwd)
        (if (string-eq cwd "")
          (ProcessSomeString "process: cwd path is empty")
          (process-env-validation-error (process-command-env command)))]
      [(ProcessNoString)
        (process-env-validation-error (process-command-env command))])))

;: Return true when `command` passes stdlib validation.
(define (process-command-valid? [command : ProcessCommand]) : bool
  (match (process-command-validation-error command)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Run a command and capture stdout, stderr, and exit status.
(define (process-output [command : ProcessCommand]) : ResultProcessOutput
  (match (process-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessOutput (ProcessInvalidCommand message))]
    [(ProcessNoString) (tl_process_output command)]))

;: Run a command using the same captured-output path as `process-output`.
(define (process-run [command : ProcessCommand]) : ResultProcessOutput
  (process-output command))

;: Start a command without waiting for process completion. The returned child
;: owns captured-output descriptors until it is passed to `process-wait`.
(define (process-start [command : ProcessCommand]) : ResultProcessChild
  (match (process-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessChild (ProcessInvalidCommand message))]
    [(ProcessNoString) (tl_process_start command)]))

;: Wait for a child started by `process-start`, collect its captured output, and
;: release the child handle resources. Do not wait on the same child twice.
(define (process-wait [child : ProcessChild]) : ResultProcessOutput
  (tl_process_wait child))