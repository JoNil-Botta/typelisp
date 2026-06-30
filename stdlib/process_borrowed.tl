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
;#
;# Owned argv/env builders also expose vector-backed construction paths. The
;# borrowed surface deliberately stays list-backed until there is a checked-in
;# borrowed vector representation: routing borrowed text through owned vectors
;# would copy before the `ProcessCommand` boundary. Ordered append helpers below
;# provide vector-style construction while preserving borrowed lifetimes and the
;# single owned-copy boundary.
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
(define (args-empty-like [_text : (& text str)]) : (ProcessBorrowedStringList
    text)
  ProcessBorrowedStringNil)

;: Return the number of borrowed argv entries in `args`.
(define (args-count [args : (ProcessBorrowedStringList text)]) : i64
  (match args
    [(ProcessBorrowedStringNil) 0]
    [(ProcessBorrowedStringCons _ rest) (+ 1 (args-count (box-get rest)))]))

;: Prepend a borrowed argument string to an argv list without copying bytes.
(define (args-cons
  [value : (& text str)]
  [rest : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (ProcessBorrowedStringCons value (box rest)))

;: Return a one-element borrowed argument list.
(define (args-single [value : (& text str)]) : (ProcessBorrowedStringList text)
  (args-cons value (args-empty-like value)))

;: Concatenate two borrowed argument lists while preserving argv order.
(define (args-append
  [left : (ProcessBorrowedStringList text)]
  [right : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (match left
    [(ProcessBorrowedStringNil) right]
    [(ProcessBorrowedStringCons value rest)
      (ProcessBorrowedStringCons value (box (args-append (box-get rest) right)))]))

;: Return an empty borrowed environment override list tied to `text`.
(define (env-empty-like [_text : (& text str)]) : (ProcessBorrowedEnvList text)
  ProcessBorrowedEnvNil)

;: Return the number of borrowed env overrides in `env`.
(define (env-count [env : (ProcessBorrowedEnvList text)]) : i64
  (match env
    [(ProcessBorrowedEnvNil) 0]
    [(ProcessBorrowedEnvCons _ _ rest) (+ 1 (env-count (box-get rest)))]))

;: Prepend borrowed environment override strings without copying bytes.
(define (env-cons
  [name : (& text str)]
  [value : (& text str)]
  [rest : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvCons name value (box rest)))

;: Return a one-element borrowed environment override list.
(define (env-single [name : (& text str)] [value : (& text str)]) : (ProcessBorrowedEnvList
    text)
  (env-cons name value (env-empty-like name)))

;: Concatenate borrowed environment override lists while preserving override
;: order. Duplicate names are preserved in list order.
(define (env-append
  [left : (ProcessBorrowedEnvList text)]
  [right : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (match left
    [(ProcessBorrowedEnvNil) right]
    [(ProcessBorrowedEnvCons name value rest)
      (ProcessBorrowedEnvCons
        name
        value
        (box (env-append (box-get rest) right)))]))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (no-string-like [_text : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  ProcessBorrowedNoString)

;: Return a borrowed stdin/cwd value without copying bytes.
(define (some-string [value : (& text str)]) : (ProcessBorrowedMaybeString text)
  (ProcessBorrowedSomeString value))

;: Return `args` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (args-normalize [args : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList
    text)
  args)

;: Return `env` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (env-normalize [env : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList
    text)
  env)

;: Return `value` through an aggregate return path so stage0 can match it after
;: this module imports process/string.
(define (maybe-normalize [value : (ProcessBorrowedMaybeString text)]) : (ProcessBorrowedMaybeString
    text)
  value)

(import stdlib.process)
(import stdlib.string)

;: Copy a borrowed string into active-arena owned storage.
(define (string-owned [value : (& value str)]) : String
  (string.substring value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (args-owned [args : (ProcessBorrowedStringList text)]) : process.ProcessStringList
  (match (args-normalize args)
    [(ProcessBorrowedStringNil) (process.args-empty)]
    [(ProcessBorrowedStringCons value rest)
      (process.args-cons (string-owned value) (args-owned (box-get rest)))]))

;: Copy borrowed env storage to the owned process env representation.
(define (env-owned [env : (ProcessBorrowedEnvList text)]) : process.ProcessEnvList
  (match (env-normalize env)
    [(ProcessBorrowedEnvNil) (process.env-empty)]
    [(ProcessBorrowedEnvCons name value rest)
      (process.env-cons
        (string-owned name)
        (string-owned value)
        (env-owned (box-get rest)))]))

;: Copy a borrowed optional string to the owned process representation.
(define (maybe-owned [value : (ProcessBorrowedMaybeString text)]) : process.ProcessMaybeString
  (match (maybe-normalize value)
    [(ProcessBorrowedNoString) (process.no-stdin)]
    [(ProcessBorrowedSomeString text)
      (process.stdin-string (string-owned text))]))

;: Construct a borrowed command with default cwd, env, and stdin settings.
(define (command
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
    (no-string-like executable)
    (env-empty-like executable)
    (no-string-like executable)))

;: Construct a borrowed command with no argv entries.
(define (command-empty [executable : (& executable str)]) : (ProcessBorrowedCommand
    executable
    executable
    executable
    executable
    executable)
  (command executable (args-empty-like executable)))

;: Return a borrowed command copy with the full argv list replaced.
(define (command-with-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [args : (ProcessBorrowedStringList next-argv)]) : (ProcessBorrowedCommand
    executable
    next-argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    args
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Return a borrowed command copy with `args` appended after existing argv
;: entries. The appended list must share the command argv lifetime.
(define (command-with-args
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [args : (ProcessBorrowedStringList argv)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (args-append (command-argv command) args)
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Construct a borrowed process command with every field supplied explicitly.
(define (command-full
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
(define (command-with-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [cwd : (& next-cwd str)]) : (ProcessBorrowedCommand
    executable
    argv
    next-cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (some-string cwd)
    (command-env command)
    (command-stdin command)))

;: Return a borrowed command copy with an additional env override. The new
;: override must share the existing env-list lifetime.
(define (command-with-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [name : (& env str)]
  [value : (& env str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (env-cons name value (command-env command))
    (command-stdin command)))

;: Return a borrowed command copy with the full env override list replaced.
(define (command-with-env-list
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [env : (ProcessBorrowedEnvList next-env)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    next-env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    env
    (command-stdin command)))

;: Return a borrowed command copy with stdin set to `stdin`.
(define (command-with-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [stdin-value : (& next-stdin str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    next-stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (command-env command)
    (some-string stdin-value)))

;: Return the borrowed executable path from `command`.
(define (command-executable
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (&
    executable
    str)
  (struct-get command executable))

;: Return the borrowed argv list from `command`.
(define (command-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedStringList
    argv)
  (struct-get command argv))

;: Return the borrowed cwd setting from `command`.
(define (command-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
    cwd)
  (struct-get command cwd))

;: Return the borrowed env override list from `command`.
(define (command-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedEnvList
    env)
  (struct-get command env))

;: Return the borrowed stdin setting from `command`.
(define (command-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
    stdin)
  (struct-get command stdin))

;: Copy borrowed command storage to the owned runtime command representation.
(define (command-owned
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ProcessCommand
  (process.command-full
    (string-owned (command-executable command))
    (args-owned (command-argv command))
    (maybe-owned (command-cwd command))
    (env-owned (command-env command))
    (maybe-owned (command-stdin command))))

;: Return the first borrowed env validation error, or `ProcessNoString`.
(define (env-validation-error [env : (ProcessBorrowedEnvList env)]) : process.ProcessMaybeString
  (match (env-normalize env)
    [(ProcessBorrowedEnvNil) (process.no-stdin)]
    [(ProcessBorrowedEnvCons name _ rest)
      (if (= (string-length name) 0)
        (process.stdin-string "process: environment variable name is empty")
        (if (process.string-contains-char? name '=')
          (process.stdin-string
            "process: environment variable name contains '='")
          (env-validation-error (box-get rest))))]))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (command-validation-error
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ProcessMaybeString
  (if (= (string-length (command-executable command)) 0)
    (process.stdin-string "process: executable path is empty")
    (match (maybe-normalize (command-cwd command))
      [(ProcessBorrowedSomeString cwd)
        (if (= (string-length cwd) 0)
          (process.stdin-string "process: cwd path is empty")
          (env-validation-error (command-env command)))]
      [(ProcessBorrowedNoString) (env-validation-error (command-env command))])))

;: Return true when a borrowed command passes stdlib validation.
(define (command-valid?
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : bool
  (not
    (process.maybe-string-info-present?
      (process.maybe-string-info (command-validation-error command)))))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `output`.
(define (output
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessOutput
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (process.ErrProcessOutput
        (process.ProcessInvalidCommand (process.maybe-string-info-value info)))
      (process.output (command-owned command)))))

;: Run a borrowed command using the same captured-output path as
;: `output`.
(define (run [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessOutput
  (output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (start
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process.ResultProcessChild
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (process.ErrProcessChild
        (process.ProcessInvalidCommand (process.maybe-string-info-value info)))
      (process.start (command-owned command)))))

;: Inline test helper that forces a borrowed process test failure.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for boolean true.
(define (test-assert-true [condition : bool]) : unit
  (if condition
    unit
    (test-fail)))

;: Inline test assertion for boolean false.
(define (test-assert-false [condition : bool]) : unit
  (test-assert-true (not condition)))

;: Inline test assertion for integer equality.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (test-assert-true (= actual expected)))

;: Inline test assertion for owned process strings.
(define (test-assert-owned-string-eq [actual : String] [expected : String]) : unit
  (test-assert-true (string.eq actual expected)))

;: Inline test assertion for a one-element owned process string list.
(define (test-assert-process-string-list1
  [items : process.ProcessStringList]
  [first : String]) : unit
  (let
    [step : process.ProcessStringStep (process.string-step items)]
    (if (process.string-step-present? step)
      (let
        [rest-step : process.ProcessStringStep
          (process.string-step (process.string-step-rest step))]
        (if (process.string-step-present? rest-step)
          (test-fail)
          (test-assert-owned-string-eq (process.string-step-value step) first)))
      (test-fail))))

;: Inline test assertion for a three-element owned process string list.
(define (test-assert-process-string-list3
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [third : String]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (if (not (process.string-step-present? a))
      (test-fail)
      (let
        [b : process.ProcessStringStep
          (process.string-step (process.string-step-rest a))]
        (if (not (process.string-step-present? b))
          (test-fail)
          (let
            [c : process.ProcessStringStep
              (process.string-step (process.string-step-rest b))]
            (if (not (process.string-step-present? c))
              (test-fail)
              (let
                [tail : process.ProcessStringStep
                  (process.string-step (process.string-step-rest c))]
                (if (process.string-step-present? tail)
                  (test-fail)
                  (begin
                    (test-assert-owned-string-eq
                      (process.string-step-value a)
                      first)
                    (test-assert-owned-string-eq
                      (process.string-step-value b)
                      second)
                    (test-assert-owned-string-eq
                      (process.string-step-value c)
                      third)))))))))))

;: Inline test assertion for an owned optional process string.
(define (test-assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]) : unit
  (let
    [info : process.ProcessMaybeStringInfo (process.maybe-string-info value)]
    (if (process.maybe-string-info-present? info)
      (test-assert-owned-string-eq
        (process.maybe-string-info-value info)
        expected)
      (test-fail))))

;: Inline test assertion for a one-element borrowed process string list.
(define (test-assert-borrowed-string-list1
  [items : (ProcessBorrowedStringList text)]
  [expected : String]) : unit
  (match (args-normalize items)
    [(ProcessBorrowedStringCons actual rest)
      (match (args-normalize (box-get rest))
        [(ProcessBorrowedStringNil)
          (test-assert-true (string.eq actual (& expected)))]
        [_ (test-fail)])]
    [(ProcessBorrowedStringNil) (test-fail)]))

;: Inline test assertion for a borrowed optional process string.
(define (test-assert-borrowed-some-string
  [value : (ProcessBorrowedMaybeString text)]
  [expected : String]) : unit
  (match (maybe-normalize value)
    [(ProcessBorrowedSomeString actual)
      (test-assert-true (string.eq actual (& expected)))]
    [(ProcessBorrowedNoString) (test-fail)]))

;: Inline test assertion for the head of an owned process environment list.
(define (test-assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (let
    [step : process.ProcessEnvStep (process.env-step env)]
    (if (process.env-step-present? step)
      (begin
        (test-assert-owned-string-eq (process.env-step-name step) expected-name)
        (test-assert-owned-string-eq
          (process.env-step-value step)
          expected-value))
      (test-fail))))

;: Inline test assertion for a two-element owned process environment list.
(define (test-assert-process-env-list2
  [env : process.ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (let
    [first : process.ProcessEnvStep (process.env-step env)]
    (if (not (process.env-step-present? first))
      (test-fail)
      (let
        [second : process.ProcessEnvStep
          (process.env-step (process.env-step-rest first))]
        (if (not (process.env-step-present? second))
          (test-fail)
          (let
            [tail : process.ProcessEnvStep
              (process.env-step (process.env-step-rest second))]
            (if (process.env-step-present? tail)
              (test-fail)
              (begin
                (test-assert-owned-string-eq
                  (process.env-step-name first)
                  first-name)
                (test-assert-owned-string-eq
                  (process.env-step-value first)
                  first-value)
                (test-assert-owned-string-eq
                  (process.env-step-name second)
                  second-name)
                (test-assert-owned-string-eq
                  (process.env-step-value second)
                  second-value)))))))))

;: Inline test assertion for the head of a borrowed process environment list.
(define (test-assert-borrowed-env-head
  [env : (ProcessBorrowedEnvList text)]
  [expected-name : String]
  [expected-value : String]) : unit
  (match (env-normalize env)
    [(ProcessBorrowedEnvCons name value _)
      (begin
        (test-assert-true (string.eq name (& expected-name)))
        (test-assert-true (string.eq value (& expected-value))))]
    [(ProcessBorrowedEnvNil) (test-fail)]))

;: Inline test assertion for invalid borrowed process output results.
(define (test-assert-invalid-output
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (begin
    (test-assert-true (process.result-invalid-command? result))
    (test-assert-owned-string-eq
      (process.result-error-message-or
        result
        "process: expected invalid output")
      message)))

;: Inline test assertion for invalid borrowed process child results.
(define (test-assert-invalid-child
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (begin
    (test-assert-true (process.child-result-invalid-command? result))
    (test-assert-owned-string-eq
      (process.child-result-error-message-or
        result
        "process: expected invalid child")
      message)))

;: Inline test body for borrowed process conversion helpers.
(define (test-api-check) : unit
  (let
    [exe : String "echo"]
    [arg : String "hello"]
    [cwd : String "target"]
    [env-pair : String "TL_BORROWED_PROCESS"]
    [stdin : String "stdin"]
    [argv : (ProcessBorrowedStringList arg) (args-single (& arg))]
    [env : (ProcessBorrowedEnvList env-pair)
      (env-cons (& env-pair) (& env-pair) (env-empty-like (& env-pair)))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (command-empty (& exe))]
    [with-argv : (ProcessBorrowedCommand exe arg exe exe exe)
      (command-with-argv base argv)]
    [with-cwd : (ProcessBorrowedCommand exe arg cwd exe exe)
      (command-with-cwd with-argv (& cwd))]
    [with-env-list : (ProcessBorrowedCommand exe arg cwd env-pair exe)
      (command-with-env-list with-cwd env)]
    [borrowed : (ProcessBorrowedCommand exe arg cwd env-pair stdin)
      (command-with-stdin with-env-list (& stdin))]
    [owned : process.ProcessCommand (command-owned borrowed)]
    (begin
      (test-assert-true (string.eq (command-executable borrowed) (& exe)))
      (test-assert-borrowed-string-list1 (command-argv borrowed) "hello")
      (test-assert-i64-eq (args-count (command-argv borrowed)) 1)
      (test-assert-borrowed-some-string (command-cwd borrowed) "target")
      (test-assert-borrowed-some-string (command-stdin borrowed) "stdin")
      (test-assert-borrowed-env-head
        (command-env borrowed)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (test-assert-i64-eq (env-count (command-env borrowed)) 1)
      (test-assert-owned-string-eq (process.command-executable owned) "echo")
      (test-assert-process-string-list1 (process.command-argv owned) "hello")
      (test-assert-process-some-string (process.command-cwd owned) "target")
      (test-assert-process-some-string (process.command-stdin owned) "stdin")
      (test-assert-process-env-head
        (process.command-env owned)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (test-assert-true (command-valid? borrowed)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (process-borrowed-test-ordered-builders-check) : unit
      (let
        [exe : String "echo"]
        [argv-pack : String "firstsecondthird"]
        [env-pack : String "TL_DUPfirstsecond"]
        [first-arg : (& argv-pack str)
          (string.substring-view (& argv-pack) 0 5)]
        [second-arg : (& argv-pack str)
          (string.substring-view (& argv-pack) 5 6)]
        [third-arg : (& argv-pack str)
          (string.substring-view (& argv-pack) 11 5)]
        [env-name : (& env-pack str) (string.substring-view (& env-pack) 0 6)]
        [env-first : (& env-pack str) (string.substring-view (& env-pack) 6 5)]
        [env-second : (& env-pack str)
          (string.substring-view (& env-pack) 11 6)]
        [tail-argv : (ProcessBorrowedStringList argv-pack)
          (args-append (args-single second-arg) (args-single third-arg))]
        [env : (ProcessBorrowedEnvList env-pack)
          (env-append
            (env-single env-name env-first)
            (env-single env-name env-second))]
        [cmd : (ProcessBorrowedCommand exe argv-pack exe env-pack exe)
          (command-with-env-list
            (command-with-args
              (command (& exe) (args-single first-arg))
              tail-argv)
            env)]
        [owned : process.ProcessCommand (command-owned cmd)]
        (begin
          (test-assert-i64-eq (args-count (command-argv cmd)) 3)
          (test-assert-process-string-list3
            (process.command-argv owned)
            "first"
            "second"
            "third")
          (test-assert-i64-eq (env-count (command-env cmd)) 2)
          (test-assert-process-env-list2
            (process.command-env owned)
            "TL_DUP"
            "first"
            "TL_DUP"
            "second"))))))

;: Inline test body for borrowed process validation helpers.
(define (test-validation-check) : unit
  (let
    [exe : String "echo"]
    [empty : String ""]
    [bad-env-name : String "BAD=NAME"]
    [empty-command : (ProcessBorrowedCommand empty empty empty empty empty)
      (command-empty (& empty))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (command-empty (& exe))]
    [empty-cwd-command : (ProcessBorrowedCommand exe exe empty exe exe)
      (command-with-cwd base (& empty))]
    [empty-env-command : (ProcessBorrowedCommand exe exe exe empty exe)
      (command-with-env-list
        base
        (env-cons (& empty) (& empty) (env-empty-like (& empty))))]
    [bad-env-command : (ProcessBorrowedCommand exe exe exe bad-env-name exe)
      (command-with-env-list
        base
        (env-cons
          (& bad-env-name)
          (& bad-env-name)
          (env-empty-like (& bad-env-name))))]
    (begin
      (test-assert-invalid-output
        (output empty-command)
        "process: executable path is empty")
      (test-assert-invalid-child
        (start empty-command)
        "process: executable path is empty")
      (test-assert-invalid-output
        (output empty-cwd-command)
        "process: cwd path is empty")
      (test-assert-invalid-output
        (output empty-env-command)
        "process: environment variable name is empty")
      (test-assert-invalid-output
        (output bad-env-command)
        "process: environment variable name contains '='")
      (test-assert-false (command-valid? empty-command)))))

(test
  process-borrowed-api
  (begin
    (test-api-check)
    (cfg feature-str-view (process-borrowed-test-ordered-builders-check) unit)
    (test-validation-check)))