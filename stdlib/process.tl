;# Process command API surface for TypeLisp (#840).
;#
;# Defines the canonical process command/output/error data model for selfhost
;# tools. Runtime process execution is provided by `process_runtime.tl` through
;# `tl_process_output`, `tl_process_start`, and `tl_process_wait`;
;# unsupported target/runtime combinations return structured errors instead of
;# routing through Rust host actions or shell-tokenized command strings.
;# Linux execution preserves inherited environment entries except names
;# provided by `ProcessEnvList`, which are replaced by the override value.
;#
;# Usage: `(import stdlib.process)`
;#
;: Immutable list of process argument strings in argv order.
(module stdlib.process)

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

;: The process-execution runtime (`tl_process_output`, `tl_process_start`,
;: `tl_process_wait`) is now implemented in TypeLisp in `process_runtime.tl`
;: (#2142 slice 4), replacing the former backend assembly. The public wrappers
;: below validate first, then call those functions. `process_runtime.tl` imports
;: this module for the shared data model.
(import stdlib.process_runtime as process_runtime_mod)

;: Return an empty argument list.
(define (process-args-empty) : ProcessStringList
  stdlib.process.ProcessStringNil)

;: Return the number of argv entries in `args`.
(define (process-args-count [args : ProcessStringList]) : i64
  (match args
    [(ProcessStringNil) 0]
    [(ProcessStringCons _ rest)
      (+ 1 (stdlib.process.process-args-count (box-get rest)))]))

;: Return argv entry `index`, or `fallback` when out of range.
(define (process-args-get
  [args : ProcessStringList]
  [index : i64]
  [fallback : String]) : String
  (if (< index 0)
    fallback
    (match args
      [(ProcessStringNil) fallback]
      [(ProcessStringCons value rest)
        (if (= index 0)
          value
          (stdlib.process.process-args-get (box-get rest) (- index 1) fallback))])))

;: Prepend an owned argument string to an argv list.
(define (process-args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (ProcessStringCons value (box rest)))

;: Return a one-element argument list backed by an owned string.
(define (process-args-single [value : String]) : ProcessStringList
  (ProcessStringCons value (box stdlib.process.ProcessStringNil)))

;: Concatenate two argument lists while preserving argv order.
(define (process-args-append
  [left : ProcessStringList]
  [right : ProcessStringList]) : ProcessStringList
  (match left
    [(ProcessStringNil) right]
    [(ProcessStringCons value rest)
      (ProcessStringCons
        value
        (box (stdlib.process.process-args-append (box-get rest) right)))]))

;: Return an empty environment override list.
(define (process-env-empty) : ProcessEnvList
  stdlib.process.ProcessEnvNil)

;: Return the number of env overrides in `env`.
(define (process-env-count [env : ProcessEnvList]) : i64
  (match env
    [(ProcessEnvNil) 0]
    [(ProcessEnvCons _ _ rest)
      (+ 1 (stdlib.process.process-env-count (box-get rest)))]))

;: Return env override name at `index`, or `fallback` when out of range.
(define (process-env-name-at
  [env : ProcessEnvList]
  [index : i64]
  [fallback : String]) : String
  (if (< index 0)
    fallback
    (match env
      [(ProcessEnvNil) fallback]
      [(ProcessEnvCons name _ rest)
        (if (= index 0)
          name
          (stdlib.process.process-env-name-at
            (box-get rest)
            (- index 1)
            fallback))])))

;: Return env override value at `index`, or `fallback` when out of range.
(define (process-env-value-at
  [env : ProcessEnvList]
  [index : i64]
  [fallback : String]) : String
  (if (< index 0)
    fallback
    (match env
      [(ProcessEnvNil) fallback]
      [(ProcessEnvCons _ value rest)
        (if (= index 0)
          value
          (stdlib.process.process-env-value-at
            (box-get rest)
            (- index 1)
            fallback))])))

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
  stdlib.process.ProcessNoString)

;: Return a command stdin value backed by an owned string.
(define (process-stdin-string [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Return a cwd value that inherits the current working directory.
(define (process-no-cwd) : ProcessMaybeString
  stdlib.process.ProcessNoString)

;: Return a cwd value that runs the command under an owned path string.
(define (process-cwd [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Construct a process command with owned executable storage and default cwd,
;: env, and stdin settings.
(define (process-command [executable : String] [argv : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    executable
    argv
    stdlib.process.ProcessNoString
    stdlib.process.ProcessEnvNil
    stdlib.process.ProcessNoString))

;: Return a copy of `command` with `arg` appended after existing argv entries.
(define (process-command-with-arg [command : ProcessCommand] [arg : String]) : ProcessCommand
  (ProcessCommand
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-args-append
      (stdlib.process.process-command-argv command)
      (stdlib.process.process-args-single arg))
    (stdlib.process.process-command-cwd command)
    (stdlib.process.process-command-env command)
    (stdlib.process.process-command-stdin command)))

;: Return a copy of `command` with `args` appended after existing argv entries.
(define (process-command-with-args
  [command : ProcessCommand]
  [args : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-args-append
      (stdlib.process.process-command-argv command)
      args)
    (stdlib.process.process-command-cwd command)
    (stdlib.process.process-command-env command)
    (stdlib.process.process-command-stdin command)))

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
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-command-argv command)
    (ProcessSomeString cwd)
    (stdlib.process.process-command-env command)
    (stdlib.process.process-command-stdin command)))

;: Return a copy of `command` with an additional env override.
(define (process-command-with-env
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (ProcessCommand
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-command-argv command)
    (stdlib.process.process-command-cwd command)
    (ProcessEnvCons
      name
      value
      (box (stdlib.process.process-command-env command)))
    (stdlib.process.process-command-stdin command)))

;: Return a copy of `command` with the full env override list replaced.
(define (process-command-with-env-list
  [command : ProcessCommand]
  [env : ProcessEnvList]) : ProcessCommand
  (ProcessCommand
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-command-argv command)
    (stdlib.process.process-command-cwd command)
    env
    (stdlib.process.process-command-stdin command)))

;: Return a copy of `command` with stdin set to `stdin`.
(define (process-command-with-stdin [command : ProcessCommand] [stdin : String]) : ProcessCommand
  (ProcessCommand
    (stdlib.process.process-command-executable command)
    (stdlib.process.process-command-argv command)
    (stdlib.process.process-command-cwd command)
    (stdlib.process.process-command-env command)
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
  (= (stdlib.process.process-output-status output) 0))

;: Return true when `result` is a successful zero-exit process output.
(define (process-result-success? [result : ResultProcessOutput]) : bool
  (match result
    [(OkProcessOutput output) (stdlib.process.process-success? output)]
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
    [(ProcessEnvNil) stdlib.process.ProcessNoString]
    [(ProcessEnvCons name _ rest)
      (if (string-eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (let
          [text : String name]
          (if (stdlib.process.process-string-contains-char? (& text) #=')
            (ProcessSomeString
              "process: environment variable name contains '='")
            (stdlib.process.process-env-validation-error (box-get rest)))))]))

;: Return the first command validation error, or `ProcessNoString`.
(define (process-command-validation-error [command : ProcessCommand]) : ProcessMaybeString
  (if (string-eq (stdlib.process.process-command-executable command) "")
    (ProcessSomeString "process: executable path is empty")
    (match (stdlib.process.process-command-cwd command)
      [(ProcessSomeString cwd)
        (if (string-eq cwd "")
          (ProcessSomeString "process: cwd path is empty")
          (stdlib.process.process-env-validation-error
            (stdlib.process.process-command-env command)))]
      [(ProcessNoString)
        (stdlib.process.process-env-validation-error
          (stdlib.process.process-command-env command))])))

;: Return true when `command` passes stdlib validation.
(define (process-command-valid? [command : ProcessCommand]) : bool
  (match (stdlib.process.process-command-validation-error command)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Run a command and capture stdout, stderr, and exit status.
(define (process-output [command : ProcessCommand]) : ResultProcessOutput
  (match (stdlib.process.process-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessOutput (ProcessInvalidCommand message))]
    [(ProcessNoString) (process_runtime_mod.tl_process_output command)]))

;: Run a command using the same captured-output path as `process-output`.
(define (process-run [command : ProcessCommand]) : ResultProcessOutput
  (stdlib.process.process-output command))

;: Start a command without waiting for process completion. The returned child
;: owns captured-output descriptors until it is passed to `process-wait`.
(define (process-start [command : ProcessCommand]) : ResultProcessChild
  (match (stdlib.process.process-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessChild (ProcessInvalidCommand message))]
    [(ProcessNoString) (process_runtime_mod.tl_process_start command)]))

;: Wait for a child started by `process-start`, collect its captured output, and
;: release the child handle resources. Do not wait on the same child twice.
(define (process-wait [child : ProcessChild]) : ResultProcessOutput
  (process_runtime_mod.tl_process_wait child))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value process-args-empty)
  (value process-args-count)
  (value process-args-get)
  (value process-args-cons)
  (value process-args-single)
  (value process-args-append)
  (value process-env-empty)
  (value process-env-count)
  (value process-env-name-at)
  (value process-env-value-at)
  (value process-env-cons)
  (value process-string-contains-char?)
  (value process-no-stdin)
  (value process-stdin-string)
  (value process-no-cwd)
  (value process-cwd)
  (value process-command)
  (value process-command-with-arg)
  (value process-command-with-args)
  (value process-command-full)
  (value process-command-with-cwd)
  (value process-command-with-env)
  (value process-command-with-env-list)
  (value process-command-with-stdin)
  (value process-command-executable)
  (value process-command-argv)
  (value process-command-cwd)
  (value process-command-env)
  (value process-command-stdin)
  (value process-output-status)
  (value process-output-stdout)
  (value process-output-stderr)
  (value process-success?)
  (value process-result-success?)
  (value process-child-started?)
  (value process-error-message)
  (value process-error-invalid-command?)
  (value process-error-spawn-failed?)
  (value process-error-wait-failed?)
  (value process-error-unsupported?)
  (value process-env-validation-error)
  (value process-command-validation-error)
  (value process-command-valid?)
  (value process-output)
  (value process-run)
  (value process-start)
  (value process-wait)
  (type ProcessStringList)
  (type ProcessMaybeString)
  (type ProcessEnvList)
  (type ProcessCommand)
  (type ProcessOutput)
  (type ProcessChild)
  (type ProcessError)
  (type ResultProcessOutput)
  (type ResultProcessChild)
  (constructor ProcessCommand)
  (constructor ProcessOutput)
  (constructor ProcessChild)
  (field ProcessCommand executable)
  (field ProcessCommand argv)
  (field ProcessCommand cwd)
  (field ProcessCommand env)
  (field ProcessCommand stdin)
  (field ProcessOutput status)
  (field ProcessOutput stdout)
  (field ProcessOutput stderr)
  (field ProcessChild pid)
  (field ProcessChild stdout-handle)
  (field ProcessChild stderr-handle)
  (variant ProcessStringNil)
  (variant ProcessStringCons)
  (variant ProcessNoString)
  (variant ProcessSomeString)
  (variant ProcessEnvNil)
  (variant ProcessEnvCons)
  (variant ProcessInvalidCommand)
  (variant ProcessSpawnFailed)
  (variant ProcessWaitFailed)
  (variant ProcessUnsupported)
  (variant OkProcessOutput)
  (variant ErrProcessOutput)
  (variant OkProcessChild)
  (variant ErrProcessChild))