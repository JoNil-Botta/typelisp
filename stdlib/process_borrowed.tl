;# Borrowed process command storage companion surface (#1915).
;#
;# `ProcessBorrowedCommand` stores executable, argv, cwd, env, and stdin text as
;# `(& lifetime str)` values without copying at each builder step. Rendering to
;# the runtime-owned `ProcessCommand` copies at the explicit compatibility
;# boundary.
;#
;# This module remains separate from `process.tl` as the explicit borrowed
;# storage companion. Runtime wrappers validate borrowed commands and copy once
;# at the owned `ProcessCommand` boundary before calling `process.tl`.
(module stdlib.process_borrowed)

;: Borrowed process argument strings in argv order. All entries in one list
;: share one lifetime; use owned conversion to join independently scoped text.
(defenum ProcessBorrowedStringList
  (:lifetimes text)
  (ProcessBorrowedStringNil)
  (ProcessBorrowedStringCons
    (& text str)
    (Box (ProcessBorrowedStringList text))))

;: Optional borrowed string value used for cwd and stdin configuration.
(defenum ProcessBorrowedMaybeString
  (:lifetimes text)
  (ProcessBorrowedNoString)
  (ProcessBorrowedSomeString (& text str)))

;: Borrowed environment override list stored as name/value pairs. All entries
;: in one list share one lifetime.
(defenum ProcessBorrowedEnvList
  (:lifetimes text)
  (ProcessBorrowedEnvNil)
  (ProcessBorrowedEnvCons
    (& text str)
    (& text str)
    (Box (ProcessBorrowedEnvList text))))

;: Borrowed process command data. The process runtime still receives owned
;: `ProcessCommand` values; borrowed commands copy at that explicit boundary.
(defstruct ProcessBorrowedCommand
  (:lifetimes executable argv cwd env stdin)
  (executable (& executable str))
  (argv (ProcessBorrowedStringList argv))
  (cwd (ProcessBorrowedMaybeString cwd))
  (env (ProcessBorrowedEnvList env))
  (stdin (ProcessBorrowedMaybeString stdin)))

;: Return an empty borrowed argument list tied to `text` without storing it.
(define (process-borrowed-args-empty-like [_text : (& text str)]) : (ProcessBorrowedStringList
    text)
  ProcessBorrowedStringNil)

;: Return the number of borrowed argv entries in `args`.
(define (process-borrowed-args-count [args : (ProcessBorrowedStringList text)]) : i64
  (match args
    [(ProcessBorrowedStringNil) 0]
    [(ProcessBorrowedStringCons _ rest)
      (+ 1 (process-borrowed-args-count (box-get rest)))]))

;: Prepend a borrowed argument string to an argv list without copying bytes.
(define (process-borrowed-args-cons
  [value : (& text str)]
  [rest : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (ProcessBorrowedStringCons value (box rest)))

;: Return a one-element borrowed argument list.
(define (process-borrowed-args-single [value : (& text str)]) : (ProcessBorrowedStringList
    text)
  (process-borrowed-args-cons value (process-borrowed-args-empty-like value)))

;: Return an empty borrowed environment override list tied to `text`.
(define (process-borrowed-env-empty-like [_text : (& text str)]) : (ProcessBorrowedEnvList
    text)
  ProcessBorrowedEnvNil)

;: Return the number of borrowed env overrides in `env`.
(define (process-borrowed-env-count [env : (ProcessBorrowedEnvList text)]) : i64
  (match env
    [(ProcessBorrowedEnvNil) 0]
    [(ProcessBorrowedEnvCons _ _ rest)
      (+ 1 (process-borrowed-env-count (box-get rest)))]))

;: Prepend borrowed environment override strings without copying bytes.
(define (process-borrowed-env-cons
  [name : (& text str)]
  [value : (& text str)]
  [rest : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvCons name value (box rest)))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (process-borrowed-no-string-like [_text : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  ProcessBorrowedNoString)

;: Return a borrowed stdin/cwd value without copying bytes.
(define (process-borrowed-some-string [value : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  (ProcessBorrowedSomeString value))

;: Return `args` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (process-borrowed-args-normalize
  [args : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  args)

;: Return `env` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (process-borrowed-env-normalize [env : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList
    text)
  env)

;: Return `value` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (process-borrowed-maybe-normalize
  [value : (ProcessBorrowedMaybeString text)]) : (ProcessBorrowedMaybeString
    text)
  value)

(import stdlib.process)
(import stdlib.string)

;: Copy a borrowed string into active-arena owned storage.
(define (process-borrowed-string-owned [value : (& value str)]) : String
  (string.substring-borrowed value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (process-borrowed-args-owned [args : (ProcessBorrowedStringList text)]) : process.ProcessStringList
  (match (process-borrowed-args-normalize args)
    [(ProcessBorrowedStringNil) (process.process-args-empty)]
    [(ProcessBorrowedStringCons value rest)
      (process.process-args-cons
        (process-borrowed-string-owned value)
        (process-borrowed-args-owned (box-get rest)))]))

;: Copy borrowed env storage to the owned process env representation.
(define (process-borrowed-env-owned [env : (ProcessBorrowedEnvList text)]) : process.ProcessEnvList
  (match (process-borrowed-env-normalize env)
    [(ProcessBorrowedEnvNil) (process.process-env-empty)]
    [(ProcessBorrowedEnvCons name value rest)
      (process.process-env-cons
        (process-borrowed-string-owned name)
        (process-borrowed-string-owned value)
        (process-borrowed-env-owned (box-get rest)))]))

;: Copy a borrowed optional string to the owned process representation.
(define (process-borrowed-maybe-owned
  [value : (ProcessBorrowedMaybeString text)]) : process.ProcessMaybeString
  (match (process-borrowed-maybe-normalize value)
    [(ProcessBorrowedNoString) (process.process-no-stdin)]
    [(ProcessBorrowedSomeString text)
      (process.process-stdin-string (process-borrowed-string-owned text))]))

;: Construct a borrowed command with default cwd, env, and stdin settings.
(define (process-borrowed-command
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]) : (ProcessBorrowedCommand
    executable
    argv
    executable
    executable
    executable)
  (ProcessBorrowedCommand
    executable
    argv
    (process-borrowed-no-string-like executable)
    (process-borrowed-env-empty-like executable)
    (process-borrowed-no-string-like executable)))

;: Construct a borrowed command with no argv entries.
(define (process-borrowed-command-empty [executable : (& executable str)]) : (ProcessBorrowedCommand
    executable
    executable
    executable
    executable
    executable)
  (process-borrowed-command
    executable
    (process-borrowed-args-empty-like executable)))

;: Return a borrowed command copy with the full argv list replaced.
(define (process-borrowed-command-with-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [args : (ProcessBorrowedStringList next-argv)]) : (ProcessBorrowedCommand
    executable
    next-argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    args
    (process-borrowed-command-cwd command)
    (process-borrowed-command-env command)
    (process-borrowed-command-stdin command)))

;: Construct a borrowed process command with every field supplied explicitly.
(define (process-borrowed-command-full
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]
  [cwd : (ProcessBorrowedMaybeString cwd)]
  [env : (ProcessBorrowedEnvList env)]
  [stdin : (ProcessBorrowedMaybeString stdin)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand executable argv cwd env stdin))

;: Return a borrowed command copy with cwd set to `cwd`.
(define (process-borrowed-command-with-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [cwd : (& next-cwd str)]) : (ProcessBorrowedCommand
    executable
    argv
    next-cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-some-string cwd)
    (process-borrowed-command-env command)
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with an additional env override. The new
;: override must share the existing env-list lifetime.
(define (process-borrowed-command-with-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [name : (& env str)]
  [value : (& env str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    (process-borrowed-env-cons
      name
      value
      (process-borrowed-command-env command))
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with the full env override list replaced.
(define (process-borrowed-command-with-env-list
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [env : (ProcessBorrowedEnvList next-env)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    next-env
    stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    env
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with stdin set to `stdin`.
(define (process-borrowed-command-with-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [stdin-value : (& next-stdin str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    next-stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    (process-borrowed-command-env command)
    (process-borrowed-some-string stdin-value)))

;: Return the borrowed executable path from `command`.
(define (process-borrowed-command-executable
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (&
    executable
    str)
  (struct-get command executable))

;: Return the borrowed argv list from `command`.
(define (process-borrowed-command-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedStringList
    argv)
  (struct-get command argv))

;: Return the borrowed cwd setting from `command`.
(define (process-borrowed-command-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
    cwd)
  (struct-get command cwd))

;: Return the borrowed env override list from `command`.
(define (process-borrowed-command-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedEnvList
    env)
  (struct-get command env))

;: Return the borrowed stdin setting from `command`.
(define (process-borrowed-command-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
    stdin)
  (struct-get command stdin))

;: Copy borrowed command storage to the owned runtime command representation.
(define (process-borrowed-command-owned
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ProcessCommand
  (process.process-command-full
    (process-borrowed-string-owned
      (process-borrowed-command-executable command))
    (process-borrowed-args-owned (process-borrowed-command-argv command))
    (process-borrowed-maybe-owned (process-borrowed-command-cwd command))
    (process-borrowed-env-owned (process-borrowed-command-env command))
    (process-borrowed-maybe-owned (process-borrowed-command-stdin command))))

;: Return the first borrowed env validation error, or `ProcessNoString`.
(define (process-borrowed-env-validation-error
  [env : (ProcessBorrowedEnvList env)]) : process.ProcessMaybeString
  (match (process-borrowed-env-normalize env)
    [(ProcessBorrowedEnvNil) (process.process-no-stdin)]
    [(ProcessBorrowedEnvCons name _ rest)
      (if (= (string-length name) 0)
        (process.process-stdin-string
          "process: environment variable name is empty")
        (if (process.process-string-contains-char? name '=')
          (process.process-stdin-string
            "process: environment variable name contains '='")
          (process-borrowed-env-validation-error (box-get rest))))]))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (process-borrowed-command-validation-error
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ProcessMaybeString
  (if (= (string-length (process-borrowed-command-executable command)) 0)
    (process.process-stdin-string "process: executable path is empty")
    (match (process-borrowed-maybe-normalize
      (process-borrowed-command-cwd command))
      [(ProcessBorrowedSomeString cwd)
        (if (= (string-length cwd) 0)
          (process.process-stdin-string "process: cwd path is empty")
          (process-borrowed-env-validation-error
            (process-borrowed-command-env command)))]
      [(ProcessBorrowedNoString)
        (process-borrowed-env-validation-error
          (process-borrowed-command-env command))])))

;: Return true when a borrowed command passes stdlib validation.
(define (process-borrowed-command-valid?
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : bool
  (not
    (process.process-maybe-string-info-present?
      (process.process-maybe-string-info
        (process-borrowed-command-validation-error command)))))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `process-output`.
(define (process-borrowed-output
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessOutput
  (let
    [info : process.ProcessMaybeStringInfo
      (process.process-maybe-string-info
        (process-borrowed-command-validation-error command))]
    (if (process.process-maybe-string-info-present? info)
      (process.ErrProcessOutput
        (process.ProcessInvalidCommand
          (process.process-maybe-string-info-value info)))
      (process.process-output (process-borrowed-command-owned command)))))

;: Run a borrowed command using the same captured-output path as
;: `process-borrowed-output`.
(define (process-borrowed-run
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessOutput
  (process-borrowed-output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (process-borrowed-start
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessChild
  (let
    [info : process.ProcessMaybeStringInfo
      (process.process-maybe-string-info
        (process-borrowed-command-validation-error command))]
    (if (process.process-maybe-string-info-present? info)
      (process.ErrProcessChild
        (process.ProcessInvalidCommand
          (process.process-maybe-string-info-value info)))
      (process.process-start (process-borrowed-command-owned command)))))

;: Inline test helper that forces a borrowed process test failure.
(define (process-borrowed-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for boolean true.
(define (process-borrowed-test-assert-true [condition : bool]) : unit
  (if condition
    unit
    (process-borrowed-test-fail)))

;: Inline test assertion for boolean false.
(define (process-borrowed-test-assert-false [condition : bool]) : unit
  (process-borrowed-test-assert-true (not condition)))

;: Inline test assertion for integer equality.
(define (process-borrowed-test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (process-borrowed-test-assert-true (= actual expected)))

;: Inline test assertion for owned process strings.
(define (process-borrowed-test-assert-owned-string-eq
  [actual : String]
  [expected : String]) : unit
  (process-borrowed-test-assert-true (string.string-eq actual expected)))

;: Inline test assertion for a one-element owned process string list.
(define (process-borrowed-test-assert-process-string-list1
  [items : process.ProcessStringList]
  [first : String]) : unit
  (let
    [step : process.ProcessStringStep (process.process-string-step items)]
    (if (process.process-string-step-present? step)
      (let
        [rest-step : process.ProcessStringStep
          (process.process-string-step (process.process-string-step-rest step))]
        (if (process.process-string-step-present? rest-step)
          (process-borrowed-test-fail)
          (process-borrowed-test-assert-owned-string-eq
            (process.process-string-step-value step)
            first)))
      (process-borrowed-test-fail))))

;: Inline test assertion for an owned optional process string.
(define (process-borrowed-test-assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]) : unit
  (let
    [info : process.ProcessMaybeStringInfo
      (process.process-maybe-string-info value)]
    (if (process.process-maybe-string-info-present? info)
      (process-borrowed-test-assert-owned-string-eq
        (process.process-maybe-string-info-value info)
        expected)
      (process-borrowed-test-fail))))

;: Inline test assertion for a one-element borrowed process string list.
(define (process-borrowed-test-assert-borrowed-string-list1
  [items : (ProcessBorrowedStringList text)]
  [expected : String]) : unit
  (match (process-borrowed-args-normalize items)
    [(ProcessBorrowedStringCons actual rest)
      (match (process-borrowed-args-normalize (box-get rest))
        [(ProcessBorrowedStringNil)
          (process-borrowed-test-assert-true
            (string.string-eq-borrowed actual (& expected)))]
        [_ (process-borrowed-test-fail)])]
    [(ProcessBorrowedStringNil) (process-borrowed-test-fail)]))

;: Inline test assertion for a borrowed optional process string.
(define (process-borrowed-test-assert-borrowed-some-string
  [value : (ProcessBorrowedMaybeString text)]
  [expected : String]) : unit
  (match (process-borrowed-maybe-normalize value)
    [(ProcessBorrowedSomeString actual)
      (process-borrowed-test-assert-true
        (string.string-eq-borrowed actual (& expected)))]
    [(ProcessBorrowedNoString) (process-borrowed-test-fail)]))

;: Inline test assertion for the head of an owned process environment list.
(define (process-borrowed-test-assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (let
    [step : process.ProcessEnvStep (process.process-env-step env)]
    (if (process.process-env-step-present? step)
      (begin
        (process-borrowed-test-assert-owned-string-eq
          (process.process-env-step-name step)
          expected-name)
        (process-borrowed-test-assert-owned-string-eq
          (process.process-env-step-value step)
          expected-value))
      (process-borrowed-test-fail))))

;: Inline test assertion for the head of a borrowed process environment list.
(define (process-borrowed-test-assert-borrowed-env-head
  [env : (ProcessBorrowedEnvList text)]
  [expected-name : String]
  [expected-value : String]) : unit
  (match (process-borrowed-env-normalize env)
    [(ProcessBorrowedEnvCons name value _)
      (begin
        (process-borrowed-test-assert-true
          (string.string-eq-borrowed name (& expected-name)))
        (process-borrowed-test-assert-true
          (string.string-eq-borrowed value (& expected-value))))]
    [(ProcessBorrowedEnvNil) (process-borrowed-test-fail)]))

;: Inline test assertion for invalid borrowed process output results.
(define (process-borrowed-test-assert-invalid-output
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (begin
    (process-borrowed-test-assert-true
      (process.process-result-invalid-command? result))
    (process-borrowed-test-assert-owned-string-eq
      (process.process-result-error-message-or
        result
        "process: expected invalid output")
      message)))

;: Inline test assertion for invalid borrowed process child results.
(define (process-borrowed-test-assert-invalid-child
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (begin
    (process-borrowed-test-assert-true
      (process.process-child-result-invalid-command? result))
    (process-borrowed-test-assert-owned-string-eq
      (process.process-child-result-error-message-or
        result
        "process: expected invalid child")
      message)))

;: Inline test body for borrowed process conversion helpers.
(define (process-borrowed-test-api-check) : unit
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
    [owned : process.ProcessCommand (process-borrowed-command-owned borrowed)]
    (begin
      (process-borrowed-test-assert-true
        (string.string-eq-borrowed
          (process-borrowed-command-executable borrowed)
          (& exe)))
      (process-borrowed-test-assert-borrowed-string-list1
        (process-borrowed-command-argv borrowed)
        "hello")
      (process-borrowed-test-assert-i64-eq
        (process-borrowed-args-count (process-borrowed-command-argv borrowed))
        1)
      (process-borrowed-test-assert-borrowed-some-string
        (process-borrowed-command-cwd borrowed)
        "target")
      (process-borrowed-test-assert-borrowed-some-string
        (process-borrowed-command-stdin borrowed)
        "stdin")
      (process-borrowed-test-assert-borrowed-env-head
        (process-borrowed-command-env borrowed)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (process-borrowed-test-assert-i64-eq
        (process-borrowed-env-count (process-borrowed-command-env borrowed))
        1)
      (process-borrowed-test-assert-owned-string-eq
        (process.process-command-executable owned)
        "echo")
      (process-borrowed-test-assert-process-string-list1
        (process.process-command-argv owned)
        "hello")
      (process-borrowed-test-assert-process-some-string
        (process.process-command-cwd owned)
        "target")
      (process-borrowed-test-assert-process-some-string
        (process.process-command-stdin owned)
        "stdin")
      (process-borrowed-test-assert-process-env-head
        (process.process-command-env owned)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (process-borrowed-test-assert-true
        (process-borrowed-command-valid? borrowed)))))

;: Inline test body for borrowed process validation helpers.
(define (process-borrowed-test-validation-check) : unit
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
      (process-borrowed-test-assert-invalid-output
        (process-borrowed-output empty-command)
        "process: executable path is empty")
      (process-borrowed-test-assert-invalid-child
        (process-borrowed-start empty-command)
        "process: executable path is empty")
      (process-borrowed-test-assert-invalid-output
        (process-borrowed-output empty-cwd-command)
        "process: cwd path is empty")
      (process-borrowed-test-assert-invalid-output
        (process-borrowed-output empty-env-command)
        "process: environment variable name is empty")
      (process-borrowed-test-assert-invalid-output
        (process-borrowed-output bad-env-command)
        "process: environment variable name contains '='")
      (process-borrowed-test-assert-false
        (process-borrowed-command-valid? empty-command)))))

(test
  process-borrowed-api
  (begin
    (process-borrowed-test-api-check)
    (process-borrowed-test-validation-check)))

(export
  (value process-borrowed-args-empty-like)
  (value process-borrowed-args-count)
  (value process-borrowed-args-cons)
  (value process-borrowed-args-single)
  (value process-borrowed-string-owned)
  (value process-borrowed-args-owned)
  (value process-borrowed-env-empty-like)
  (value process-borrowed-env-count)
  (value process-borrowed-env-cons)
  (value process-borrowed-env-owned)
  (value process-borrowed-no-string-like)
  (value process-borrowed-some-string)
  (value process-borrowed-maybe-owned)
  (value process-borrowed-command)
  (value process-borrowed-command-empty)
  (value process-borrowed-command-with-argv)
  (value process-borrowed-command-full)
  (value process-borrowed-command-with-cwd)
  (value process-borrowed-command-with-env)
  (value process-borrowed-command-with-env-list)
  (value process-borrowed-command-with-stdin)
  (value process-borrowed-command-executable)
  (value process-borrowed-command-argv)
  (value process-borrowed-command-cwd)
  (value process-borrowed-command-env)
  (value process-borrowed-command-stdin)
  (value process-borrowed-command-owned)
  (value process-borrowed-env-validation-error)
  (value process-borrowed-command-validation-error)
  (value process-borrowed-command-valid?)
  (value process-borrowed-output)
  (value process-borrowed-run)
  (value process-borrowed-start)
  (type ProcessBorrowedStringList)
  (type ProcessBorrowedMaybeString)
  (type ProcessBorrowedEnvList)
  (type ProcessBorrowedCommand)
  (constructor ProcessBorrowedCommand)
  (field ProcessBorrowedCommand executable)
  (field ProcessBorrowedCommand argv)
  (field ProcessBorrowedCommand cwd)
  (field ProcessBorrowedCommand env)
  (field ProcessBorrowedCommand stdin)
  (variant ProcessBorrowedStringNil)
  (variant ProcessBorrowedStringCons)
  (variant ProcessBorrowedNoString)
  (variant ProcessBorrowedSomeString)
  (variant ProcessBorrowedEnvNil)
  (variant ProcessBorrowedEnvCons))