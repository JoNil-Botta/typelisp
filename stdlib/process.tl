;# Process command API surface for TypeLisp (#840).
;#
;# Defines the canonical process command/output/error data model for selfhost
;# tools. Runtime process execution is provided by `process_runtime.tl` through
;# `tl_process_output`, `tl_process_start`, and `tl_process_wait`;
;# unsupported target/runtime combinations return structured errors instead of
;# routing through Rust host actions or shell-tokenized command strings.
;# Linux execution preserves inherited environment entries except names
;# provided by `ProcessEnvList`, which are replaced by the override value.
;# `ProcessEnvVec` is a vector-backed companion that converts to the same
;# list-backed runtime boundary: inherited entries matching any override name
;# are removed, overrides are emitted in vector order, and duplicate override
;# names are preserved in vector order.
;#
;# Usage: `(import "stdlib/process.tl")`
;#
(import "vector.tl")

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

;: Vector-backed process environment overrides. `names` and `values` are
;: parallel `StringVec` buffers with the invariant that their live lengths are
;: equal. Runtime execution still consumes `ProcessEnvList`; converting this
;: representation preserves vector order and keeps duplicate names.
(defstruct ProcessEnvVec
  (names StringVec)
  (values StringVec))

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
(import "process_runtime.tl")

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

;: Convert a `StringVec` argv buffer to the list representation consumed by
;: `ProcessCommand`, preserving vector order.
(define (process-args-from-string-vec-from
  [args : StringVec]
  [index : i64]
  [out : ProcessStringList]) : ProcessStringList
  (if (< index 0)
    out
    (process-args-from-string-vec-from
      args
      (- index 1)
      (process-args-cons (string-vec-get args index "") out))))

;: Convert a `StringVec` argv buffer to the list representation consumed by
;: `ProcessCommand`, preserving vector order.
(define (process-args-from-string-vec [args : StringVec]) : ProcessStringList
  (process-args-from-string-vec-from
    args
    (- (string-vec-len args) 1)
    (ProcessStringNil)))

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

;: Return the name buffer from a vector-backed env override set.
(define (process-env-vec-names [env : ProcessEnvVec]) : StringVec
  (struct-get env names))

;: Return the value buffer from a vector-backed env override set.
(define (process-env-vec-values [env : ProcessEnvVec]) : StringVec
  (struct-get env values))

;: Create an empty vector-backed env override set with at least `capacity`
;: backing slots in each parallel buffer.
(define (process-env-vec-with-capacity [capacity : i64]) : ProcessEnvVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ProcessEnvVec
      (string-vec-with-capacity cap)
      (string-vec-with-capacity cap))))

;: Create an empty vector-backed env override set.
(define (process-env-vec-new) : ProcessEnvVec
  (process-env-vec-with-capacity 4))

;: Return the number of vector-backed env overrides. Helper-created values keep
;: this equal to the live length of both buffers; manually constructed values
;: should be checked with `process-env-vec-validation-error`.
(define (process-env-vec-count [env : ProcessEnvVec]) : i64
  (string-vec-len (process-env-vec-names env)))

;: Append one owned environment override at the end of the vector-backed set.
;: Duplicate names are preserved in append order.
(define (process-env-vec-append
  [env : ProcessEnvVec]
  [name : String]
  [value : String]) : ProcessEnvVec
  (ProcessEnvVec
    (string-vec-push (process-env-vec-names env) name)
    (string-vec-push (process-env-vec-values env) value)))

;: Convert vector-backed env overrides to a list, preserving vector order at
;: the existing runtime boundary.
(define (process-env-vec-to-list-from
  [env : ProcessEnvVec]
  [index : i64]
  [out : ProcessEnvList]) : ProcessEnvList
  (if (< index 0)
    out
    (process-env-vec-to-list-from
      env
      (- index 1)
      (ProcessEnvCons
        (string-vec-get (process-env-vec-names env) index "")
        (string-vec-get (process-env-vec-values env) index "")
        (box out)))))

;: Convert vector-backed env overrides to the list representation consumed by
;: `ProcessCommand` and the process runtime.
(define (process-env-vec-to-list [env : ProcessEnvVec]) : ProcessEnvList
  (process-env-vec-to-list-from
    env
    (- (process-env-vec-count env) 1)
    (ProcessEnvNil)))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
(define (process-env-vec-validation-error-from
  [env : ProcessEnvVec]
  [index : i64]) : ProcessMaybeString
  (if (>= index (process-env-vec-count env))
    (ProcessNoString)
    (let
      [name : String (string-vec-get (process-env-vec-names env) index "")]
      (if (string-eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (if (process-string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")
          (process-env-vec-validation-error-from env (+ index 1)))))))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
;: The inherited environment is filtered by names that appear in the override
;: set, then override entries are emitted in vector order. Duplicate override
;: names are preserved in vector order.
(define (process-env-vec-validation-error [env : ProcessEnvVec]) : ProcessMaybeString
  (if (not
    (=
      (string-vec-len (process-env-vec-names env))
      (string-vec-len (process-env-vec-values env))))
    (ProcessSomeString "process: environment vector name/value counts differ")
    (process-env-vec-validation-error-from env 0)))

;: Return true when vector-backed env overrides satisfy the public invariant and
;: all override names are valid.
(define (process-env-vec-valid? [env : ProcessEnvVec]) : bool
  (match (process-env-vec-validation-error env)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

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

;: Construct a process command from an executable and a vector-backed argv
;: buffer. The command keeps the existing list-backed ABI after one conversion.
(define (process-command-from-argv-vec [executable : String] [argv : StringVec]) : ProcessCommand
  (process-command executable (process-args-from-string-vec argv)))

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

;: Return a copy of `command` with the full argv list replaced by a
;: vector-backed argv buffer converted once at the compatibility boundary.
(define (process-command-with-argv-vec
  [command : ProcessCommand]
  [argv : StringVec]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-from-string-vec argv)
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with vector-backed args appended after existing
;: argv entries through one list conversion and one list append.
(define (process-command-with-args-vec
  [command : ProcessCommand]
  [args : StringVec]) : ProcessCommand
  (process-command-with-args command (process-args-from-string-vec args)))

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

;: Return a copy of `command` with env overrides replaced by vector-backed
;: storage converted to the existing list-backed runtime boundary.
(define (process-command-with-env-vec
  [command : ProcessCommand]
  [env : ProcessEnvVec]) : ProcessCommand
  (process-command-with-env-list command (process-env-vec-to-list env)))

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
          (if (process-string-contains-char? (& text) '=')
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

;: Inline test failure helper.
(define (process-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (process-test-assert [ok : bool]) : unit
  (if ok
    unit
    (process-test-fail)))

;: Inline test integer assertion.
(define (process-test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (process-test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (process-test-assert-string-eq [actual : String] [expected : String]) : unit
  (process-test-assert (string-eq actual expected)))

;: Inline test assertion for an empty process string list.
(define (process-test-assert-string-empty [items : ProcessStringList]) : unit
  (match items
    [(ProcessStringNil) unit]
    [(ProcessStringCons _ _) (process-test-fail)]))

;: Inline test assertion for a one-item process string list.
(define (process-test-assert-string-list1
  [items : ProcessStringList]
  [first : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringNil) (process-test-assert-string-eq a first)]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a two-item process string list.
(define (process-test-assert-string-list2
  [items : ProcessStringList]
  [first : String]
  [second : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringCons b tail)
          (match (box-get tail)
            [(ProcessStringNil)
              (begin
                (process-test-assert-string-eq a first)
                (process-test-assert-string-eq b second))]
            [_ (process-test-fail)])]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a three-item process string list.
(define (process-test-assert-string-list3
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [third : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringCons b more)
          (match (box-get more)
            [(ProcessStringCons c tail)
              (match (box-get tail)
                [(ProcessStringNil)
                  (begin
                    (process-test-assert-string-eq a first)
                    (process-test-assert-string-eq b second)
                    (process-test-assert-string-eq c third))]
                [_ (process-test-fail)])]
            [_ (process-test-fail)])]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a present optional process string.
(define (process-test-assert-some-string
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (process-test-assert-string-eq actual expected)]
    [(ProcessNoString) (process-test-fail)]))

;: Inline test assertion for an absent optional process string.
(define (process-test-assert-no-string [value : ProcessMaybeString]) : unit
  (match value
    [(ProcessNoString) unit]
    [(ProcessSomeString _) (process-test-fail)]))

;: Inline test assertion for the head of a process environment list.
(define (process-test-assert-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (process-test-assert-string-eq name expected-name)
        (process-test-assert-string-eq value expected-value))]
    [(ProcessEnvNil) (process-test-fail)]))

;: Inline test assertion for a two-entry process environment list.
(define (process-test-assert-env-list2
  [env : ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (match env
    [(ProcessEnvCons name value rest)
      (begin
        (process-test-assert-string-eq name first-name)
        (process-test-assert-string-eq value first-value)
        (match (box-get rest)
          [(ProcessEnvCons next-name next-value tail)
            (begin
              (process-test-assert-string-eq next-name second-name)
              (process-test-assert-string-eq next-value second-value)
              (match (box-get tail)
                [(ProcessEnvNil) unit]
                [_ (process-test-fail)]))]
          [(ProcessEnvNil) (process-test-fail)]))]
    [(ProcessEnvNil) (process-test-fail)]))

;: Inline test assertion for process validation diagnostics.
(define (process-test-assert-validation
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (process-test-assert-string-eq actual expected)]
    [(ProcessNoString) (process-test-fail)]))

;: Inline test body for command and argv helpers.
(define (process-test-command-api) : unit
  (let
    [args : ProcessStringList
      (process-args-cons
        "hello"
        (process-args-cons "world" (process-args-empty)))]
    [command : ProcessCommand
      (process-command-with-arg
        (process-command-with-env
          (process-command-with-stdin
            (process-command-with-cwd (process-command "echo" args) "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (process-test-assert-string-eq
        (process-command-executable command)
        "echo")
      (process-test-assert-string-list2 args "hello" "world")
      (process-test-assert-string-list3
        (process-command-argv command)
        "hello"
        "world"
        "!")
      (process-test-assert-i64-eq
        (process-args-count (process-command-argv command))
        3)
      (process-test-assert-string-list3
        (process-args-append args (process-args-single "again"))
        "hello"
        "world"
        "again")
      (process-test-assert-string-empty
        (process-args-from-string-vec (string-vec-new)))
      (process-test-assert-string-list1
        (process-args-from-string-vec (string-vec-push (string-vec-new) "solo"))
        "solo")
      (process-test-assert-string-list3
        (process-args-from-string-vec
          (string-vec-push
            (string-vec-push
              (string-vec-push (string-vec-with-capacity 3) "hello")
              "world")
            "!"))
        "hello"
        "world"
        "!")
      (process-test-assert-string-empty
        (process-command-argv
          (process-command-from-argv-vec "echo" (string-vec-new))))
      (process-test-assert-string-list1
        (process-command-argv
          (process-command-from-argv-vec
            "echo"
            (string-vec-push (string-vec-new) "solo")))
        "solo")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-from-argv-vec
            "echo"
            (string-vec-push
              (string-vec-push
                (string-vec-push (string-vec-with-capacity 3) "hello")
                "world")
              "!")))
        "hello"
        "world"
        "!")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-with-argv-vec
            command
            (string-vec-push
              (string-vec-push
                (string-vec-push (string-vec-with-capacity 3) "vec")
                "replace")
              "argv")))
        "vec"
        "replace"
        "argv")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-with-args-vec
            (process-command "echo" (process-args-single "base"))
            (string-vec-push
              (string-vec-push (string-vec-with-capacity 2) "vec")
              "tail")))
        "base"
        "vec"
        "tail")
      (process-test-assert-some-string (process-command-cwd command) "target")
      (process-test-assert-some-string (process-command-stdin command) "stdin")
      (process-test-assert-env-head (process-command-env command) "TL_TEST" "1")
      (process-test-assert-i64-eq
        (process-env-count (process-command-env command))
        1)
      (process-test-assert-env-head
        (process-command-env
          (process-command-with-env-list
            command
            (process-env-cons "TL_REPLACED" "yes" (process-env-empty))))
        "TL_REPLACED"
        "yes")
      (process-test-assert-no-string
        (process-command-cwd (process-command "echo" (process-args-empty)))))))

;: Inline test body for vector-backed environment helpers.
(define (process-test-env-vec-api [command : ProcessCommand]) : unit
  (let
    [env-vec-empty : ProcessEnvVec (process-env-vec-new)]
    [env-vec : ProcessEnvVec
      (process-env-vec-append
        (process-env-vec-append (process-env-vec-new) "TL_FIRST" "one")
        "TL_SECOND"
        "two")]
    [env-dup : ProcessEnvVec
      (process-env-vec-append
        (process-env-vec-append (process-env-vec-new) "TL_DUP" "first")
        "TL_DUP"
        "second")]
    [bad-shape : ProcessEnvVec
      (ProcessEnvVec
        (string-vec-push (string-vec-new) "ONLY_NAME")
        (string-vec-new))]
    (begin
      (process-test-assert-i64-eq (process-env-vec-count env-vec-empty) 0)
      (process-test-assert (process-env-vec-valid? env-vec-empty))
      (process-test-assert-i64-eq (process-env-vec-count env-vec) 2)
      (process-test-assert (process-env-vec-valid? env-vec))
      (process-test-assert-env-list2
        (process-env-vec-to-list env-vec)
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (process-test-assert-env-list2
        (process-command-env (process-command-with-env-vec command env-vec))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (process-test-assert-env-list2
        (process-env-vec-to-list env-dup)
        "TL_DUP"
        "first"
        "TL_DUP"
        "second")
      (process-test-assert-validation
        (process-env-vec-validation-error
          (process-env-vec-append (process-env-vec-new) "" "bad"))
        "process: environment variable name is empty")
      (process-test-assert-validation
        (process-env-vec-validation-error
          (process-env-vec-append (process-env-vec-new) "BAD=NAME" "bad"))
        "process: environment variable name contains '='")
      (process-test-assert-validation
        (process-env-vec-validation-error bad-shape)
        "process: environment vector name/value counts differ"))))

;: Inline test body for validation and result helpers.
(define (process-test-validation-api) : unit
  (let
    [command : ProcessCommand
      (process-command-with-env
        (process-command-with-cwd
          (process-command "echo" (process-args-empty))
          "target")
        "TL_TEST"
        "1")]
    (begin
      (process-test-env-vec-api command)
      (process-test-assert-validation
        (process-command-validation-error
          (process-command "" (process-args-empty)))
        "process: executable path is empty")
      (process-test-assert-validation
        (process-command-validation-error (process-command-with-cwd command ""))
        "process: cwd path is empty")
      (process-test-assert-validation
        (process-command-validation-error
          (process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (process-test-assert-validation
        (process-command-validation-error
          (process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (process-test-assert (process-command-valid? command))
      (process-test-assert
        (not (process-command-valid? (process-command "" (process-args-empty)))))
      (process-test-assert
        (process-result-success? (OkProcessOutput (ProcessOutput 0 "" ""))))
      (process-test-assert
        (not
          (process-result-success? (OkProcessOutput (ProcessOutput 7 "" "")))))
      (process-test-assert
        (not
          (process-result-success?
            (ErrProcessOutput (ProcessSpawnFailed "spawn failed")))))
      (process-test-assert
        (process-error-invalid-command?
          (ProcessInvalidCommand "invalid command")))
      (process-test-assert
        (process-error-spawn-failed? (ProcessSpawnFailed "spawn failed")))
      (process-test-assert
        (process-error-wait-failed? (ProcessWaitFailed "wait failed")))
      (process-test-assert
        (process-error-unsupported? (ProcessUnsupported "unsupported")))
      (process-test-assert
        (process-child-started? (OkProcessChild (ProcessChild 1 2 3))))
      (process-test-assert
        (not
          (process-child-started?
            (ErrProcessChild (ProcessUnsupported "unsupported"))))))))

(test
  process-api
  (begin
    (process-test-command-api)
    (process-test-validation-api)))