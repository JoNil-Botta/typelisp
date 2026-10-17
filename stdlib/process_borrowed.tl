;# Borrowed process command storage companion surface.
;#
;# `ProcessBorrowedCommand` stores executable, argv, cwd, env, and stdin text as
;# `(& lifetime str)` values without copying at each builder step. Rendering to
;# the runtime-owned `ProcessCommand` copies at the explicit compatibility
;# boundary.
;# Command builders consume their command and move its list storage. Accessors
;# borrow that storage, so finish using a field borrow before moving the command
;# into another builder. Clone a command explicitly to retain both versions.
;#
;# This module remains separate from `process.tl` as the explicit borrowed
;# storage companion. Runtime wrappers validate borrowed commands and copy once
;# at the owned `ProcessCommand` boundary before calling `process.tl`.
;#
;# Borrowed commands use the inherited environment policy; for an exact child
;# environment apply `process.command-with-exact-env-list` to `command-owned`.
;#
;# Owned argv/env builders also expose vector-backed construction paths.
;# Borrowed builders use typed persistent nodes, so safe constructors cannot
;# inject raw reference words. Bytes are not copied before the explicit owned
;# boundary.
(import stdlib.io)

;: Borrowed process argument strings in argv order. All entries in one list
;: share one lifetime; use owned conversion to join independently scoped text.
(defenum ProcessBorrowedStringList
  (:lifetimes text)
  (ProcessBorrowedStringNil (& text str))
  (ProcessBorrowedStringCons
    (& text str)
    (Box (ProcessBorrowedStringList text))))

;: Optional borrowed string value used for cwd and stdin configuration.
(defenum ProcessBorrowedMaybeString
  (:lifetimes text)
  (ProcessBorrowedNoString)
  (ProcessBorrowedSomeString (& text str)))

;: Borrowed environment name/value pair. Both strings share the `text` lifetime.
(defstruct ProcessBorrowedEnvEntry
  (:lifetimes text)
  (name (& text str))
  (value (& text str)))

;: Persistent borrowed environment override list. All entries share the `text`
;: lifetime and are stored as typed name/value reference pairs.
(defenum ProcessBorrowedEnvList
  (:lifetimes text)
  (ProcessBorrowedEnvNil (& text str))
  (ProcessBorrowedEnvCons
    (& text str)
    (& text str)
    (Box (ProcessBorrowedEnvList text))))

;: Borrowed mirror of the public command-storage count cap.
(define process-borrowed-storage-max-count : i64
  4096)

;: Borrowed mirror of the per-field C-string byte cap.
(define process-borrowed-storage-max-string-bytes : i64
  1048576)

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
  (ProcessBorrowedStringNil _text))

;: Return the number of borrowed argv entries in `args`, saturated at one past
;: the implementation cap for oversized externally constructed spines.
(define (args-count [args : (& args (ProcessBorrowedStringList text))]) : i64
  (let
    [cursor : (& args (ProcessBorrowedStringList text)) args]
    [count : i64 0]
    [walking : bool true]
    (while walking
      (if (>= count process-borrowed-storage-max-count)
        (begin
          (set! count (+ process-borrowed-storage-max-count 1))
          (set! walking false))
        (match cursor
          [(ProcessBorrowedStringNil _) (set! walking false)]
          [(ProcessBorrowedStringCons _ rest)
            (set! cursor rest)
            (set! count (+ count 1))])))
    count))

;: Return the borrowed argv entry at a valid `index`. Callers must validate
;: indexes against `args-count`; no owned string is created.
(define (args-ref
  [args : (& args (ProcessBorrowedStringList text))]
  [index : i64]) : (& text str)
  (if (< index 0)
    (io.panic "process: borrowed argument index out of bounds")
    (match args
      [(ProcessBorrowedStringNil _)
        (io.panic "process: borrowed argument index out of bounds")]
      [(ProcessBorrowedStringCons value rest)
        (if (= index 0)
          value
          (args-ref rest (- index 1)))])))

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
    [(ProcessBorrowedStringNil _) right]
    [(ProcessBorrowedStringCons value rest)
      (ProcessBorrowedStringCons value (box (args-append (deref rest) right)))]))

;: Return an empty borrowed environment override list tied to `text`.
(define (env-empty-like [_text : (& text str)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvNil _text))

;: Return the number of borrowed env overrides in `env`, saturated at one past
;: the implementation cap for oversized externally constructed spines.
(define (env-count [env : (& env (ProcessBorrowedEnvList text))]) : i64
  (let
    [cursor : (& env (ProcessBorrowedEnvList text)) env]
    [count : i64 0]
    [walking : bool true]
    (while walking
      (if (>= count process-borrowed-storage-max-count)
        (begin
          (set! count (+ process-borrowed-storage-max-count 1))
          (set! walking false))
        (match cursor
          [(ProcessBorrowedEnvNil _) (set! walking false)]
          [(ProcessBorrowedEnvCons _ _ rest)
            (set! cursor rest)
            (set! count (+ count 1))])))
    count))

;: Return a borrowed environment entry at a valid `index`.
(define (env-entry-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (ProcessBorrowedEnvEntry text)
  (if (< index 0)
    (io.panic "process: borrowed environment index out of bounds")
    (match env
      [(ProcessBorrowedEnvNil _)
        (io.panic "process: borrowed environment index out of bounds")]
      [(ProcessBorrowedEnvCons name value rest)
        (if (= index 0)
          (ProcessBorrowedEnvEntry name value)
          (env-entry-ref rest (- index 1)))])))

;: Return a borrowed environment name at a valid `index`.
(define (env-name-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (& text str)
  (let
    [entry : (ProcessBorrowedEnvEntry text) (env-entry-ref env index)]
    entry.name))

;: Return a borrowed environment value at a valid `index`.
(define (env-value-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (& text str)
  (let
    [entry : (ProcessBorrowedEnvEntry text) (env-entry-ref env index)]
    entry.value))

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
    [(ProcessBorrowedEnvNil _) right]
    [(ProcessBorrowedEnvCons name value rest)
      (ProcessBorrowedEnvCons name value (box (env-append (deref rest) right)))]))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (no-string-like [_text : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  ProcessBorrowedNoString)

;: Return a borrowed stdin/cwd value without copying bytes.
(define (some-string [value : (& text str)]) : (ProcessBorrowedMaybeString text)
  (ProcessBorrowedSomeString value))

;: Return `args` through an aggregate return path for imported callers.
(define (args-normalize [args : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList
    text)
  args)

;: Return `env` through an aggregate return path for imported callers.
(define (env-normalize [env : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList
    text)
  env)

;: Return `value` through an aggregate return path for imported callers.
(define (maybe-normalize [value : (ProcessBorrowedMaybeString text)]) : (ProcessBorrowedMaybeString
    text)
  value)

;: Return the borrowed executable path from `command`.
(define (command-executable
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    executable
    str)
  command.executable)

;: Return the borrowed argv list from `command`.
(define (command-argv
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    command
    (ProcessBorrowedStringList argv))
  (& command.argv))

;: Return the borrowed cwd setting from `command`.
(define (command-cwd
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    command
    (ProcessBorrowedMaybeString cwd))
  (& command.cwd))

;: Return the borrowed env override list from `command`.
(define (command-env
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    command
    (ProcessBorrowedEnvList env))
  (& command.env))

;: Return the borrowed stdin setting from `command`.
(define (command-stdin
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    command
    (ProcessBorrowedMaybeString stdin))
  (& command.stdin))

(import stdlib.process)
(import stdlib.string)

;: Copy a borrowed string into active-arena owned storage.
(define (string-owned [value : (& value str)]) : String
  (string.substring value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (args-owned [args : (& args (ProcessBorrowedStringList text))]) : process.ProcessStringList
  (let
    [n : i64 (args-count args)]
    (if (> n process-borrowed-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (let
        [slots : (__tl_dyn-array String) (__tl_make-array String n)]
        [cursor : (& args (ProcessBorrowedStringList text)) args]
        [index : i64 0]
        [walking : bool true]
        (while walking
          (match cursor
            [(ProcessBorrowedStringNil _) (set! walking false)]
            [(ProcessBorrowedStringCons value rest)
              (set! (array-ref slots index) (string-owned value))
              (set! cursor rest)
              (set! index (+ index 1))]))
        (process.ProcessStringList slots)))))

;: Copy borrowed env storage to the owned process env representation.
(define (env-owned [env : (& env (ProcessBorrowedEnvList text))]) : process.ProcessEnvList
  (let
    [n : i64 (env-count env)]
    (if (> n process-borrowed-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (let
        [names : (__tl_dyn-array String) (__tl_make-array String n)]
        [values : (__tl_dyn-array String) (__tl_make-array String n)]
        [cursor : (& env (ProcessBorrowedEnvList text)) env]
        [index : i64 0]
        [walking : bool true]
        (while walking
          (match cursor
            [(ProcessBorrowedEnvNil _) (set! walking false)]
            [(ProcessBorrowedEnvCons name value rest)
              (set! (array-ref names index) (string-owned name))
              (set! (array-ref values index) (string-owned value))
              (set! cursor rest)
              (set! index (+ index 1))]))
        (process.ProcessEnvList names values)))))

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

;: Consume `command` and replace its full argv list.
(define (command-with-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [args : (ProcessBorrowedStringList next-argv)]) : (ProcessBorrowedCommand
    executable
    next-argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    command.executable
    args
    command.cwd
    command.env
    command.stdin))

;: Consume `command` and append `args` after its existing argv
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
    command.executable
    (args-append command.argv args)
    command.cwd
    command.env
    command.stdin))

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

;: Consume `command` and set its cwd to `cwd`.
(define (command-with-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [cwd : (& next-cwd str)]) : (ProcessBorrowedCommand
    executable
    argv
    next-cwd
    env
    stdin)
  (ProcessBorrowedCommand
    command.executable
    command.argv
    (some-string cwd)
    command.env
    command.stdin))

;: Consume `command` and add an env override. The new
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
    command.executable
    command.argv
    command.cwd
    (env-cons name value command.env)
    command.stdin))

;: Consume `command` and replace its full env override list.
(define (command-with-env-list
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [env : (ProcessBorrowedEnvList next-env)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    next-env
    stdin)
  (ProcessBorrowedCommand
    command.executable
    command.argv
    command.cwd
    env
    command.stdin))

;: Consume `command` and set its stdin to `stdin-value`.
(define (command-with-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [stdin-value : (& next-stdin str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    next-stdin)
  (ProcessBorrowedCommand
    command.executable
    command.argv
    command.cwd
    command.env
    (some-string stdin-value)))

;: Copy borrowed command storage to the owned runtime command representation.
(define (command-owned
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ProcessCommand
  (process.command-full
    (string-owned (command-executable command))
    (args-owned (command-argv command))
    (maybe-owned (deref (command-cwd command)))
    (env-owned (command-env command))
    (maybe-owned (deref (command-stdin command)))))

;: Return the first borrowed argv validation error, or `ProcessNoString`.
(define (args-validation-error-from
  [args : (& args (ProcessBorrowedStringList text))]
  [count : i64]) : process.ProcessMaybeString
  (match args
    [(ProcessBorrowedStringNil _) (process.no-stdin)]
    [(ProcessBorrowedStringCons value rest)
      (cond
        [(>= count process-borrowed-storage-max-count)
          (process.stdin-string "process: argument storage limit exceeded")]
        [(> (string-length value) process-borrowed-storage-max-string-bytes)
          (process.stdin-string "process: argument exceeds storage limit")]
        [(process.string-contains-char? value '\0')
          (process.stdin-string "process: argument contains NUL")]
        [else (args-validation-error-from rest (+ count 1))])]))

;: Return the first borrowed argv validation error, including the storage cap.
(define (args-validation-error
  [args : (& args (ProcessBorrowedStringList text))]) : process.ProcessMaybeString
  (args-validation-error-from args 0))

;: Return the first borrowed env validation error, or `ProcessNoString`.
(define (env-validation-error-from
  [env : (& env (ProcessBorrowedEnvList text))]
  [count : i64]) : process.ProcessMaybeString
  (match env
    [(ProcessBorrowedEnvNil _) (process.no-stdin)]
    [(ProcessBorrowedEnvCons name value rest)
      (cond
        [(>= count process-borrowed-storage-max-count)
          (process.stdin-string "process: environment storage limit exceeded")]
        [(= (string-length name) 0)
          (process.stdin-string "process: environment variable name is empty")]
        [(process.string-contains-char? name '=')
          (process.stdin-string
            "process: environment variable name contains '='")]
        [(> (string-length name) process-borrowed-storage-max-string-bytes)
          (process.stdin-string
            "process: environment variable name exceeds storage limit")]
        [(> (string-length value) process-borrowed-storage-max-string-bytes)
          (process.stdin-string
            "process: environment variable value exceeds storage limit")]
        [(process.string-contains-char? name '\0')
          (process.stdin-string
            "process: environment variable name contains NUL")]
        [(process.string-contains-char? value '\0')
          (process.stdin-string
            "process: environment variable value contains NUL")]
        [else (env-validation-error-from rest (+ count 1))])]))

;: Return the first borrowed environment validation error, or `ProcessNoString`.
(define (env-validation-error [env : (& env (ProcessBorrowedEnvList text))]) : process.ProcessMaybeString
  (env-validation-error-from env 0))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (command-validation-error
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ProcessMaybeString
  (let
    [argv-view : (& command (ProcessBorrowedStringList argv))
      (command-argv command)]
    [env-view : (& command (ProcessBorrowedEnvList env)) (command-env command)]
    (cond
      [(= (string-length (command-executable command)) 0)
        (process.stdin-string "process: executable path is empty")]
      [(>
          (string-length (command-executable command))
          process-borrowed-storage-max-string-bytes)
        (process.stdin-string "process: executable path exceeds storage limit")]
      [(process.string-contains-char? (command-executable command) '\0')
        (process.stdin-string "process: executable path contains NUL")]
      [else
        (match (args-validation-error argv-view)
          [(ProcessSomeString message) (process.stdin-string message)]
          [(ProcessNoString)
            (match (command-cwd command)
              [(ProcessBorrowedSomeString cwd)
                (cond
                  [(= (string-length cwd) 0)
                    (process.stdin-string "process: cwd path is empty")]
                  [(>
                      (string-length cwd)
                      process-borrowed-storage-max-string-bytes)
                    (process.stdin-string
                      "process: cwd path exceeds storage limit")]
                  [(process.string-contains-char? cwd '\0')
                    (process.stdin-string "process: cwd path contains NUL")]
                  [else (env-validation-error env-view)])]
              [(ProcessBorrowedNoString) (env-validation-error env-view)])])])))

;: Return true when a borrowed command passes stdlib validation.
(define (command-valid?
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : bool
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (not (process.maybe-string-info-present? info))))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `output`.
(define (output
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessOutput
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (ErrProcessOutput (ProcessInvalidCommand info.value))
      (process.output (command-owned command)))))

;: Run a borrowed command using the same captured-output path as
;: `output`.
(define (run
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessOutput
  (output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (start
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessChild
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (ErrProcessChild (ProcessInvalidCommand info.value))
      (process.start (command-owned command)))))

;: Inline test helper that forces a borrowed process test failure.
(define (test-fail) : unit
  (/ 1 0)
  unit)

;: Build one owned test string with an embedded NUL byte.
(define (test-string-with-nul) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data bytes))]
    (set! (array-ref bytes 0) (cast 'a' : u8))
    (set! (array-ref bytes 1) (cast 0 : u8))
    (set! (array-ref bytes 2) (cast 'b' : u8))
    (unsafe
      (string-from-bytes (ptr-cast dst : (Ptr u8)) 3))))

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

;: Inline test assertion for process strings.
(define (test-assert-owned-string-eq
  [actual : (& actual str)]
  [expected : (& expected str)]) : unit
  (test-assert-true (string.eq actual expected)))

;: Inline test assertion for a one-element owned process string list, stepped
;: with `string-step`; each value is read before its step is consumed.
(define (test-assert-process-string-list1
  [items : process.ProcessStringList]
  [first : (& first str)]) : unit
  (let
    [step : process.ProcessStringStep (process.string-step items)]
    (test-assert-true (process.string-step-present? step))
    (test-assert-owned-string-eq (process.string-step-value step) first)
    (test-assert-false
      (process.string-step-present?
        (& (process.string-step (process.string-step-rest step)))))))

;: Inline test assertion for a three-element owned process string list.
(define (test-assert-process-string-list3
  [items : process.ProcessStringList]
  [first : (& first str)]
  [second : (& second str)]
  [third : (& third str)]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (test-assert-true (process.string-step-present? a))
    (test-assert-owned-string-eq (process.string-step-value a) first)
    (let
      [b : process.ProcessStringStep
        (process.string-step (process.string-step-rest a))]
      (test-assert-true (process.string-step-present? b))
      (test-assert-owned-string-eq (process.string-step-value b) second)
      (let
        [c : process.ProcessStringStep
          (process.string-step (process.string-step-rest b))]
        (test-assert-true (process.string-step-present? c))
        (test-assert-owned-string-eq (process.string-step-value c) third)
        (test-assert-false
          (process.string-step-present?
            (& (process.string-step (process.string-step-rest c)))))))))

;: Inline test assertion for an optional process string.
(define (test-assert-process-some-string
  [value : (& value process.ProcessMaybeString)]
  [expected : (& expected str)]) : unit
  (match value
    [(ProcessSomeString text) (test-assert-owned-string-eq text expected)]
    [(ProcessNoString) (test-fail)]))

;: Inline test assertion for a one-element borrowed process string list.
(define (test-assert-borrowed-string-list1
  [items : (& items (ProcessBorrowedStringList text))]
  [expected : (& expected str)]) : unit
  (test-assert-i64-eq (args-count items) 1)
  (test-assert-true (string.eq (args-ref items 0) expected)))

;: Inline test assertion for a borrowed optional process string.
(define (test-assert-borrowed-some-string
  [value : (& value (ProcessBorrowedMaybeString text))]
  [expected : (& expected str)]) : unit
  (match value
    [(ProcessBorrowedSomeString actual)
      (test-assert-true (string.eq actual expected))]
    [(ProcessBorrowedNoString) (test-fail)]))

;: Inline test assertion for the head of an owned process environment list,
;: stepped with `env-step`.
(define (test-assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : (& expected-name str)]
  [expected-value : (& expected-value str)]) : unit
  (let
    [step : process.ProcessEnvStep (process.env-step env)]
    (test-assert-true (process.env-step-present? step))
    (test-assert-owned-string-eq (process.env-step-name step) expected-name)
    (test-assert-owned-string-eq (process.env-step-value step) expected-value)))

;: Inline test assertion for a two-element owned process environment list.
(define (test-assert-process-env-list2
  [env : process.ProcessEnvList]
  [first-name : (& first-name str)]
  [first-value : (& first-value str)]
  [second-name : (& second-name str)]
  [second-value : (& second-value str)]) : unit
  (let
    [first : process.ProcessEnvStep (process.env-step env)]
    (test-assert-true (process.env-step-present? first))
    (test-assert-owned-string-eq (process.env-step-name first) first-name)
    (test-assert-owned-string-eq (process.env-step-value first) first-value)
    (let
      [second : process.ProcessEnvStep
        (process.env-step (process.env-step-rest first))]
      (test-assert-true (process.env-step-present? second))
      (test-assert-owned-string-eq (process.env-step-name second) second-name)
      (test-assert-owned-string-eq (process.env-step-value second) second-value)
      (test-assert-false
        (process.env-step-present?
          (& (process.env-step (process.env-step-rest second))))))))

;: Inline test assertion for the head of a borrowed process environment list.
(define (test-assert-borrowed-env-head
  [env : (& env (ProcessBorrowedEnvList text))]
  [expected-name : (& expected-name str)]
  [expected-value : (& expected-value str)]) : unit
  (test-assert-true (> (env-count env) 0))
  (test-assert-true (string.eq (env-name-ref env 0) expected-name))
  (test-assert-true (string.eq (env-value-ref env 0) expected-value)))

;: Inline test assertion for invalid borrowed process output results.
(define (test-assert-invalid-output
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (test-assert-owned-string-eq
    (process.result-error-message-or result "process: expected invalid output")
    message))

;: Inline test assertion for invalid borrowed process child results.
(define (test-assert-invalid-child
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (test-assert-owned-string-eq
    (process.child-result-error-message-or
      result
      "process: expected invalid child")
    message))

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
    [borrowed-argv : (& borrowed (ProcessBorrowedStringList arg))
      (command-argv borrowed)]
    [borrowed-env : (& borrowed (ProcessBorrowedEnvList env-pair))
      (command-env borrowed)]
    (test-assert-true (string.eq (command-executable borrowed) (& exe)))
    (test-assert-borrowed-string-list1 borrowed-argv "hello")
    (test-assert-i64-eq (args-count borrowed-argv) 1)
    (test-assert-borrowed-some-string (command-cwd borrowed) "target")
    (test-assert-borrowed-some-string (command-stdin borrowed) "stdin")
    (test-assert-borrowed-env-head
      borrowed-env
      "TL_BORROWED_PROCESS"
      "TL_BORROWED_PROCESS")
    (test-assert-i64-eq (env-count borrowed-env) 1)
    (test-assert-owned-string-eq (process.command-executable owned) "echo")
    (test-assert-process-string-list1 (process.command-argv owned) "hello")
    (test-assert-process-some-string (process.command-cwd owned) "target")
    (test-assert-process-some-string (process.command-stdin owned) "stdin")
    (test-assert-process-env-head
      (process.command-env owned)
      "TL_BORROWED_PROCESS"
      "TL_BORROWED_PROCESS")
    (test-assert-true (command-valid? borrowed))))

(cfg
  test
  (define (process-borrowed-test-ordered-builders-check) : unit
    (let
      [exe : String "echo"]
      [argv-pack : String "firstsecondthird"]
      [env-pack : String "TL_DUPfirstsecond"]
      [first-arg : (& argv-pack str) (string.substring-view (& argv-pack) 0 5)]
      [second-arg : (& argv-pack str) (string.substring-view (& argv-pack) 5 6)]
      [third-arg : (& argv-pack str) (string.substring-view (& argv-pack) 11 5)]
      [empty-args : (ProcessBorrowedStringList argv-pack)
        (args-empty-like first-arg)]
      [single-arg : (ProcessBorrowedStringList argv-pack)
        (args-single first-arg)]
      [env-name : (& env-pack str) (string.substring-view (& env-pack) 0 6)]
      [env-first : (& env-pack str) (string.substring-view (& env-pack) 6 5)]
      [env-second : (& env-pack str) (string.substring-view (& env-pack) 11 6)]
      [empty-env : (ProcessBorrowedEnvList env-pack) (env-empty-like env-name)]
      [single-env : (ProcessBorrowedEnvList env-pack)
        (env-single env-name env-first)]
      [tail-argv : (ProcessBorrowedStringList argv-pack)
        (args-append (args-single second-arg) (args-single third-arg))]
      [env : (ProcessBorrowedEnvList env-pack)
        (env-append
          (env-single env-name env-first)
          (env-single env-name env-second))]
      [first-command : (ProcessBorrowedCommand exe argv-pack exe exe exe)
        (command (& exe) (args-single first-arg))]
      [args-command : (ProcessBorrowedCommand exe argv-pack exe exe exe)
        (command-with-args first-command tail-argv)]
      [cmd : (ProcessBorrowedCommand exe argv-pack exe env-pack exe)
        (command-with-env-list args-command env)]
      [owned : process.ProcessCommand (command-owned cmd)]
      [cmd-argv : (& cmd (ProcessBorrowedStringList argv-pack))
        (command-argv cmd)]
      [cmd-env : (& cmd (ProcessBorrowedEnvList env-pack)) (command-env cmd)]
      (test-assert-i64-eq (args-count empty-args) 0)
      (test-assert-i64-eq (args-count single-arg) 1)
      (test-assert-true (string.eq (args-ref single-arg 0) first-arg))
      (test-assert-i64-eq (env-count empty-env) 0)
      (test-assert-i64-eq (env-count single-env) 1)
      (test-assert-true (string.eq (env-name-ref single-env 0) env-name))
      (test-assert-true (string.eq (env-value-ref single-env 0) env-first))
      (test-assert-i64-eq (args-count cmd-argv) 3)
      (test-assert-process-string-list3
        (process.command-argv owned)
        "first"
        "second"
        "third")
      (test-assert-i64-eq (env-count cmd-env) 2)
      (test-assert-process-env-list2
        (process.command-env owned)
        "TL_DUP"
        "first"
        "TL_DUP"
        "second"))))

;: Inline test body for borrowed process validation helpers.
(define (test-validation-check) : unit
  (let
    [exe : String "echo"]
    [empty : String ""]
    [bad-env-name : String "BAD=NAME"]
    [with-nul : String (test-string-with-nul)]
    [nul-valid-name : (& with-nul str) (string.substring-view (& with-nul) 0 1)]
    [empty-command : (ProcessBorrowedCommand empty empty empty empty empty)
      (command-empty (& empty))]
    [empty-cwd-command : (ProcessBorrowedCommand exe exe empty exe exe)
      (command-with-cwd (command-empty (& exe)) (& empty))]
    [empty-env-command : (ProcessBorrowedCommand exe exe exe empty exe)
      (command-with-env-list
        (command-empty (& exe))
        (env-cons (& empty) (& empty) (env-empty-like (& empty))))]
    [bad-env-command : (ProcessBorrowedCommand exe exe exe bad-env-name exe)
      (command-with-env-list
        (command-empty (& exe))
        (env-cons
          (& bad-env-name)
          (& bad-env-name)
          (env-empty-like (& bad-env-name))))]
    [nul-executable-command : (ProcessBorrowedCommand
      with-nul
      with-nul
      with-nul
      with-nul
      with-nul)
      (command-empty (& with-nul))]
    [nul-argument-command : (ProcessBorrowedCommand exe with-nul exe exe exe)
      (command-with-argv (command-empty (& exe)) (args-single (& with-nul)))]
    [nul-cwd-command : (ProcessBorrowedCommand exe exe with-nul exe exe)
      (command-with-cwd (command-empty (& exe)) (& with-nul))]
    [nul-env-name-command : (ProcessBorrowedCommand exe exe exe with-nul exe)
      (command-with-env-list
        (command-empty (& exe))
        (env-cons (& with-nul) (& with-nul) (env-empty-like (& with-nul))))]
    [nul-env-value-command : (ProcessBorrowedCommand exe exe exe with-nul exe)
      (command-with-env-list
        (command-empty (& exe))
        (env-cons nul-valid-name (& with-nul) (env-empty-like (& with-nul))))]
    [nul-stdin-command : (ProcessBorrowedCommand exe exe exe exe with-nul)
      (command-with-stdin (command-empty (& exe)) (& with-nul))]
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
    (test-assert-invalid-output
      (output nul-executable-command)
      "process: executable path contains NUL")
    (test-assert-invalid-output
      (output nul-argument-command)
      "process: argument contains NUL")
    (test-assert-invalid-output
      (output nul-cwd-command)
      "process: cwd path contains NUL")
    (test-assert-invalid-output
      (output nul-env-name-command)
      "process: environment variable name contains NUL")
    (test-assert-invalid-output
      (output nul-env-value-command)
      "process: environment variable value contains NUL")
    (test-assert-true (command-valid? nul-stdin-command))
    (test-assert-false (command-valid? empty-command))))

(test
  process-borrowed-api
  (test-api-check)
  (process-borrowed-test-ordered-builders-check)
  (test-validation-check))