(import stdlib.process)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (assert-owned-string-eq
  [actual : (& actual str)]
  [expected : (& expected str)]
  [message : (& message str)]) : unit
  (test.assert-string-eq actual expected (string.copy message)))

;; `items` holds exactly the listed entries, read through `args-ref`.
(define (assert-process-string-list
  [items : (& items process.ProcessStringList)]
  [first : (& first str)]
  [second : (& second str)]
  [message : (& message str)]) : unit
  (test.assert-i64-eq (process.args-count items) 2 (string.copy message))
  (assert-owned-string-eq (& (process.args-ref items 0)) first message)
  (assert-owned-string-eq (& (process.args-ref items 1)) second message))

(define (assert-process-string-empty
  [items : (& items process.ProcessStringList)]
  [message : (& message str)]) : unit
  (test.assert-i64-eq (process.args-count items) 0 (string.copy message)))

(define (assert-process-string-list1
  [items : (& items process.ProcessStringList)]
  [first : (& first str)]
  [message : (& message str)]) : unit
  (test.assert-i64-eq (process.args-count items) 1 (string.copy message))
  (assert-owned-string-eq (& (process.args-ref items 0)) first message))

(define (assert-process-string-list3
  [items : (& items process.ProcessStringList)]
  [first : (& first str)]
  [second : (& second str)]
  [third : (& third str)]
  [message : (& message str)]) : unit
  (test.assert-i64-eq (process.args-count items) 3 (string.copy message))
  (assert-owned-string-eq (& (process.args-ref items 0)) first message)
  (assert-owned-string-eq (& (process.args-ref items 1)) second message)
  (assert-owned-string-eq (& (process.args-ref items 2)) third message))

;; Steps through an owned three-entry list with `string-step`, reading each
;; value before the step is consumed for its tail.
(define (assert-process-string-steps3
  [items : process.ProcessStringList]
  [first : (& first str)]
  [second : (& second str)]
  [third : (& third str)]
  [message : (& message str)]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (test.assert-true (process.string-step-present? a) (string.copy message))
    (assert-owned-string-eq (process.string-step-value a) first message)
    (let
      [b : process.ProcessStringStep
        (process.string-step (process.string-step-rest a))]
      (test.assert-true (process.string-step-present? b) (string.copy message))
      (assert-owned-string-eq (process.string-step-value b) second message)
      (let
        [c : process.ProcessStringStep
          (process.string-step (process.string-step-rest b))]
        (test.assert-true
          (process.string-step-present? c)
          (string.copy message))
        (assert-owned-string-eq (process.string-step-value c) third message)
        (test.assert-false
          (process.string-step-present?
            (& (process.string-step (process.string-step-rest c))))
          (string.copy message))))))

(define (assert-process-some-string
  [value : (& value process.ProcessMaybeString)]
  [expected : (& expected str)]
  [message : (& message str)]) : unit
  (match value
    [(process.ProcessSomeString text)
      (assert-owned-string-eq text expected message)]
    [(process.ProcessNoString) (io.panic message)]))

(define (assert-process-no-string
  [value : (& value process.ProcessMaybeString)]
  [message : (& message str)]) : unit
  (match value
    [(process.ProcessSomeString _) (io.panic message)]
    [(process.ProcessNoString) unit]))

;; Reads an owned optional string through `maybe-string-info`.
(define (assert-process-some-string-info
  [value : process.ProcessMaybeString]
  [expected : (& expected str)]
  [message : (& message str)]) : unit
  (let
    [info : process.ProcessMaybeStringInfo (process.maybe-string-info value)]
    (test.assert-true
      (process.maybe-string-info-present? info)
      (string.copy message))
    (assert-owned-string-eq
      (process.maybe-string-info-value info)
      expected
      message)))

(define (assert-process-env-head
  [env : (& env process.ProcessEnvList)]
  [expected-name : (& expected-name str)]
  [expected-value : (& expected-value str)]
  [message : (& message str)]) : unit
  (test.assert-true (> (process.env-count env) 0) (string.copy message))
  (assert-owned-string-eq
    (& (process.env-name-ref env 0))
    expected-name
    message)
  (assert-owned-string-eq
    (& (process.env-value-ref env 0))
    expected-value
    message))

(define (assert-process-env-list2
  [env : (& env process.ProcessEnvList)]
  [first-name : (& first-name str)]
  [first-value : (& first-value str)]
  [second-name : (& second-name str)]
  [second-value : (& second-value str)]
  [message : (& message str)]) : unit
  (test.assert-i64-eq (process.env-count env) 2 (string.copy message))
  (assert-owned-string-eq (& (process.env-name-ref env 0)) first-name message)
  (assert-owned-string-eq (& (process.env-value-ref env 0)) first-value message)
  (assert-owned-string-eq (& (process.env-name-ref env 1)) second-name message)
  (assert-owned-string-eq
    (& (process.env-value-ref env 1))
    second-value
    message))

;; Steps through an owned two-row env list with `env-step`, reading each row
;; before the step is consumed for its tail.
(define (assert-process-env-steps2
  [env : process.ProcessEnvList]
  [first-name : (& first-name str)]
  [first-value : (& first-value str)]
  [second-name : (& second-name str)]
  [second-value : (& second-value str)]
  [message : (& message str)]) : unit
  (let
    [first : process.ProcessEnvStep (process.env-step env)]
    (test.assert-true (process.env-step-present? first) (string.copy message))
    (assert-owned-string-eq (process.env-step-name first) first-name message)
    (assert-owned-string-eq (process.env-step-value first) first-value message)
    (let
      [second : process.ProcessEnvStep
        (process.env-step (process.env-step-rest first))]
      (test.assert-true
        (process.env-step-present? second)
        (string.copy message))
      (assert-owned-string-eq
        (process.env-step-name second)
        second-name
        message)
      (assert-owned-string-eq
        (process.env-step-value second)
        second-value
        message)
      (test.assert-false
        (process.env-step-present?
          (& (process.env-step (process.env-step-rest second))))
        (string.copy message)))))

(define (assert-process-env-validation
  [value : process.ProcessMaybeString]
  [expected : (& expected str)]
  [message : (& message str)]) : unit
  (assert-process-some-string-info value expected message))

(define (process-api-string-vec0) : svec.Vec
  (svec.new))

(define (process-api-string-vec1 [a : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (svec.push-ref! (&mut items) a)
    items))

(define (process-api-string-vec2 [a : String] [b : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 2)]
    (svec.push-ref! (&mut items) a)
    (svec.push-ref! (&mut items) b)
    items))

(define (process-api-string-vec3 [a : String] [b : String] [c : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 3)]
    (svec.push-ref! (&mut items) a)
    (svec.push-ref! (&mut items) b)
    (svec.push-ref! (&mut items) c)
    items))

(define (process-api-env-vec1 [name : String] [value : String]) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (process.env-vec-append! (&mut env) name value)
    env))

(define (process-api-env-vec2
  [name-a : String]
  [value-a : String]
  [name-b : String]
  [value-b : String]) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (process.env-vec-append! (&mut env) name-a value-a)
    (process.env-vec-append! (&mut env) name-b value-b)
    env))

(define (process-api-bad-shape-env-vec) : process.ProcessEnvVec
  (let
    [names : svec.Vec (svec.new)]
    [values : svec.Vec (svec.new)]
    (svec.push-ref! (&mut names) "ONLY_NAME")
    (process.ProcessEnvVec names values)))

(define (process-api-forged-live-length-env-vec) : process.ProcessEnvVec
  (let
    [names : svec.Vec (svec.Vec (__tl_make-array String 0) 1)]
    [values : svec.Vec (svec.Vec (__tl_make-array String 0) 1)]
    (process.ProcessEnvVec names values)))

(define (assert-process-invalid-command
  [result : process.ResultProcessOutput]
  [message : (& message str)]) : unit
  (test.assert-true
    (process.result-invalid-command? (clone result))
    (string.copy message))
  (assert-owned-string-eq
    (process.result-error-message-or result "ok")
    (string.copy message)
    message))

(define (assert-process-child-invalid-command
  [result : process.ResultProcessChild]
  [message : (& message str)]) : unit
  (test.assert-true
    (process.child-result-invalid-command? (clone result))
    (string.copy message))
  (assert-owned-string-eq
    (process.child-result-error-message-or result "ok")
    (string.copy message)
    message))

(define (process-api-string-with-nul) : String
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

(define (process-api-malformed-env-command) : process.ProcessCommand
  (let
    [names : (__tl_dyn-array String) (__tl_make-array String 1)]
    [values : (__tl_dyn-array String) (__tl_make-array String 0)]
    (set! (array-ref names 0) "ONLY_NAME")
    (process.command-full
      "echo"
      (process.args-empty)
      (process.no-cwd)
      (process.ProcessEnvList names values)
      (process.no-stdin))))

(define (process-api-oversized-argv-command) : process.ProcessCommand
  (let
    [slots : (__tl_dyn-array String)
      (__tl_make-array String (+ process.process-storage-max-count 1))]
    (process.command "echo" (process.ProcessStringList slots))))

;; A string of `n` repeated "a" bytes, built by doubling.
(define (process-api-repeat-a [n : i64]) : String
  (let
    [text : String "a"]
    (while (< (string-length (& text)) n)
      (set! text (str_cat.str-cat (string.copy (& text)) text)))
    (string.substring text 0 n)))

(define (process-api-exact-command [env : process.ProcessEnvList]) : process.ProcessCommand
  (process.command-with-exact-env-list
    (process.command "echo" (process.args-empty))
    env))

(define (process-api-env2
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : process.ProcessEnvList
  (process.env-cons
    first-name
    first-value
    (process.env-cons second-name second-value (process.env-empty))))

;; #7547: every constructor and `command-with-env*` builder selects the
;; inherited policy, `command-with-exact-env*` selects exact, and the other
;; builders keep the policy they were given.
(define (assert-process-env-policy-api) : unit
  (let
    [exact : process.ProcessCommand
      (process-api-exact-command (process.env-empty))]
    (test.assert-false
      (process.command-env-exact?
        (& (process.command "echo" (process.args-empty))))
      "command defaults to the inherited environment")
    (test.assert-false
      (process.command-env-exact?
        (&
          (process.command-full
            "echo"
            (process.args-empty)
            (process.no-cwd)
            (process.env-empty)
            (process.no-stdin))))
      "command-full inherits")
    (test.assert-true (process.command-env-exact? (& exact)) "exact env list")
    (test.assert-true
      (process.command-env-exact?
        (&
          (process.command-with-stdin
            (process.command-with-cwd
              (process.command-with-args
                (process.command-with-arg (clone exact) "a")
                (process.args-single "b"))
              "target")
            "in")))
      "argv, cwd and stdin builders keep the exact policy")
    (test.assert-true
      (process.command-env-exact?
        (& (process.command-with-exact-env (clone exact) "A" "1")))
      "exact env row builder")
    (test.assert-true
      (process.command-env-exact?
        (&
          (process.command-with-exact-env-vec
            (process.command "echo" (process.args-empty))
            (& (process-api-env-vec1 "A" "1")))))
      "exact env vec builder")
    (test.assert-false
      (process.command-env-exact?
        (& (process.command-with-env (clone exact) "A" "1")))
      "command-with-env selects the inherited policy")
    (test.assert-false
      (process.command-env-exact?
        (& (process.command-with-env-list (clone exact) (process.env-empty))))
      "command-with-env-list selects the inherited policy")
    (test.assert-true
      (process.command-valid? (& exact))
      "an empty exact environment is valid")
    ;; Inherited overrides keep their duplicate semantics.
    (test.assert-true
      (process.command-valid?
        (&
          (process.command-with-env-list
            (process.command "echo" (process.args-empty))
            (process-api-env2 "DUP" "1" "DUP" "2"))))
      "inherited overrides may repeat a name")
    (assert-process-env-validation
      (process.command-validation-error
        (& (process-api-exact-command (process-api-env2 "DUP" "1" "DUP" "2"))))
      "process: exact environment repeats a variable name"
      "exact env rejects a repeated name")
    (let
      [case-collision : process.ProcessMaybeString
        (process.command-validation-error
          (&
            (process-api-exact-command (process-api-env2 "Path" "1" "PATH" "2"))))]
      (cfg
        windows
        (assert-process-env-validation
          case-collision
          "process: exact environment repeats a variable name"
          "windows exact names compare case-insensitively")
        (assert-process-no-string
          case-collision
          "linux exact names compare bytewise")))
    ;; A row's own error comes before the exact-environment checks.
    (assert-process-env-validation
      (process.command-validation-error
        (& (process-api-exact-command (process-api-env2 "" "1" "" "2"))))
      "process: environment variable name is empty"
      "exact env reports a row error first")
    ;; Two rows at the per-field cap overflow the block cap by 6 bytes; one row
    ;; fits.
    (assert-process-env-validation
      (process.command-validation-error
        (&
          (process-api-exact-command
            (process-api-env2
              "A"
              (process-api-repeat-a process.process-storage-max-string-bytes)
              "B"
              (process-api-repeat-a process.process-storage-max-string-bytes)))))
      "process: exact environment exceeds storage limit"
      "exact env rejects rows past the block cap")
    (assert-process-no-string
      (&
        (process.command-validation-error
          (&
            (process-api-exact-command
              (process.env-cons
                "A"
                (process-api-repeat-a process.process-storage-max-string-bytes)
                (process.env-empty))))))
      "exact env accepts one row at the field cap")
    ;; The cap is inclusive and each row costs `NAME=VALUE\0`: rows totalling
    ;; exactly the cap are accepted, and one byte more is rejected.
    (assert-process-no-string
      (&
        (process.command-validation-error
          (&
            (process-api-exact-command
              (process-api-env2
                "A"
                (process-api-repeat-a process.process-storage-max-string-bytes)
                "B"
                (process-api-repeat-a
                  (- process.process-storage-max-string-bytes 6)))))))
      "exact env accepts rows totalling exactly the block cap")
    (assert-process-env-validation
      (process.command-validation-error
        (&
          (process-api-exact-command
            (process-api-env2
              "A"
              (process-api-repeat-a process.process-storage-max-string-bytes)
              "B"
              (process-api-repeat-a
                (- process.process-storage-max-string-bytes 5))))))
      "process: exact environment exceeds storage limit"
      "exact env rejects rows one byte past the block cap")
    (assert-process-invalid-command
      (process.output
        (process-api-exact-command (process-api-env2 "DUP" "1" "DUP" "2")))
      "process: exact environment repeats a variable name")))

(define (process-api-step-boundaries) : unit
  (let
    [empty : process.ProcessStringStep
      (process.string-step (process.args-empty))]
    [single : process.ProcessStringStep
      (process.string-step (process.args-single "one"))]
    [env : process.ProcessEnvStep (process.env-step (process.env-empty))]
    [none : process.ProcessMaybeStringInfo
      (process.maybe-string-info (process.no-stdin))]
    (test.assert-false (process.string-step-present? empty) "empty argv step")
    (assert-owned-string-eq
      (process.string-step-value empty)
      ""
      "empty argv value")
    (assert-process-string-empty
      (& (process.string-step-rest empty))
      "empty argv tail")
    (test.assert-true (process.string-step-present? single) "single argv step")
    (assert-owned-string-eq
      (process.string-step-value single)
      "one"
      "single argv value")
    (assert-process-string-empty
      (& (process.string-step-rest single))
      "single argv tail")
    (test.assert-false (process.env-step-present? env) "empty env step")
    (assert-owned-string-eq (process.env-step-name env) "" "empty env name")
    (assert-owned-string-eq (process.env-step-value env) "" "empty env value")
    (test.assert-i64-eq
      (process.env-count (& (process.env-step-rest env)))
      0
      "empty env tail")
    (test.assert-false
      (process.maybe-string-info-present? none)
      "empty string info")
    (assert-owned-string-eq
      (process.maybe-string-info-value none)
      ""
      "empty info value"))
  (assert-process-string-steps3
    (process.args-cons
      "first"
      (process.args-cons "second" (process.args-single "third")))
    "first"
    "second"
    "third"
    "owned argv steps")
  (assert-process-env-steps2
    (process.env-cons
      "FIRST"
      "one"
      (process.env-cons "SECOND" "two" (process.env-empty)))
    "FIRST"
    "one"
    "SECOND"
    "two"
    "owned env steps"))

(define (main) : i64
  (process-api-step-boundaries)
  (let
    [args : process.ProcessStringList
      (process.args-cons
        "hello"
        (process.args-cons "world" (process.args-empty)))]
    [command : process.ProcessCommand
      (process.command-with-arg
        (process.command-with-env
          (process.command-with-stdin
            (process.command-with-cwd
              (process.command "echo" (clone args))
              "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    [default-command : process.ProcessCommand
      (process.command "echo" (process.args-empty))]
    [invalid-command : process.ProcessCommand
      (process.command "" (process.args-empty))]
    [nul-stdin-command : process.ProcessCommand
      (process.command-with-stdin
        (process.command "echo" (process.args-empty))
        (process-api-string-with-nul))]
    (test.assert-i64-eq
      (process.process-checked-count-add
        (- process.process-storage-max-count 1)
        1)
      process.process-storage-max-count
      "process checked count accepts exact cap")
    (process.test-env-dense-api)
    (assert-process-env-policy-api)
    (assert-owned-string-eq
      (process.command-executable command)
      "echo"
      "process executable")
    (assert-process-string-list (& (clone args)) "hello" "world" "process argv")
    (assert-process-string-list3
      (& (process.command-argv command))
      "hello"
      "world"
      "!"
      "process argv append")
    (let
      [command-args : process.ProcessStringList (process.command-argv command)]
      (test.assert-i64-eq
        (process.args-count command-args)
        3
        "process argv count"))
    (assert-process-string-list3
      (& (process.args-append args (process.args-single "again")))
      "hello"
      "world"
      "again"
      "process args append")
    (let
      [empty-argv : svec.Vec (process-api-string-vec0)]
      [solo-argv : svec.Vec (process-api-string-vec1 "solo")]
      [multi-argv : svec.Vec (process-api-string-vec3 "hello" "world" "!")]
      [replace-argv : svec.Vec (process-api-string-vec3 "vec" "replace" "argv")]
      [tail-argv : svec.Vec (process-api-string-vec2 "vec" "tail")]
      [empty-command : process.ProcessCommand
        (process.command-from-argv-vec "echo" (& empty-argv))]
      [solo-command : process.ProcessCommand
        (process.command-from-argv-vec "echo" (& solo-argv))]
      [multi-command : process.ProcessCommand
        (process.command-from-argv-vec "echo" (& multi-argv))]
      [replace-command : process.ProcessCommand
        (process.command-with-argv-vec (clone command) (& replace-argv))]
      [append-command : process.ProcessCommand
        (process.command-with-args-vec
          (process.command "echo" (process.args-single "base"))
          (& tail-argv))]
      (assert-process-string-empty
        (& (process.args-from-string-vec (& empty-argv)))
        "process argv vec empty")
      (assert-process-string-list1
        (& (process.args-from-string-vec (& solo-argv)))
        "solo"
        "process argv vec single")
      (assert-process-string-list3
        (& (process.args-from-string-vec (& multi-argv)))
        "hello"
        "world"
        "!"
        "process argv vec multi")
      (assert-process-string-empty
        (& (process.command-argv empty-command))
        "process command argv vec empty")
      (assert-process-string-list1
        (& (process.command-argv solo-command))
        "solo"
        "process command argv vec single")
      (assert-process-string-list3
        (& (process.command-argv multi-command))
        "hello"
        "world"
        "!"
        "process command argv vec multi")
      (assert-process-string-list3
        (& (process.command-argv replace-command))
        "vec"
        "replace"
        "argv"
        "process command argv vec replace")
      (assert-process-string-list3
        (& (process.command-argv append-command))
        "base"
        "vec"
        "tail"
        "process command argv vec append"))
    (assert-process-some-string
      (process.command-cwd command)
      "target"
      "process cwd")
    (assert-process-some-string
      (process.command-stdin command)
      "stdin"
      "process stdin")
    (assert-process-env-head
      (& (process.command-env command))
      "TL_TEST"
      "1"
      "process env")
    (let
      [command-env : process.ProcessEnvList (process.command-env command)]
      (test.assert-i64-eq (process.env-count command-env) 1 "process env count"))
    (let
      [replaced-env-command : process.ProcessCommand
        (process.command-with-env-list
          (clone command)
          (process.env-cons "TL_REPLACED" "yes" (process.env-empty)))]
      (assert-process-env-head
        (& (process.command-env replaced-env-command))
        "TL_REPLACED"
        "yes"
        "process env list"))
    (let
      [env-vec-empty : process.ProcessEnvVec (process.env-vec-new)]
      [env-vec : process.ProcessEnvVec
        (process-api-env-vec2 "TL_FIRST" "one" "TL_SECOND" "two")]
      [env-dup : process.ProcessEnvVec
        (process-api-env-vec2 "TL_DUP" "first" "TL_DUP" "second")]
      [bad-empty : process.ProcessEnvVec (process-api-env-vec1 "" "bad")]
      [bad-name : process.ProcessEnvVec (process-api-env-vec1 "BAD=NAME" "bad")]
      [bad-shape : process.ProcessEnvVec (process-api-bad-shape-env-vec)]
      [bad-live-length : process.ProcessEnvVec
        (process-api-forged-live-length-env-vec)]
      [env-command : process.ProcessCommand
        (process.command-with-env-vec (clone command) (& env-vec))]
      (test.assert-i64-eq
        (process.env-vec-count (& env-vec-empty))
        0
        "process env vec empty count")
      (test.assert-true
        (process.env-vec-valid? (& env-vec-empty))
        "process env vec empty valid")
      (test.assert-i64-eq
        (process.env-vec-count (& env-vec))
        2
        "process env vec count")
      (test.assert-true
        (process.env-vec-valid? (& env-vec))
        "process env vec valid")
      (assert-process-env-list2
        (& (process.env-vec-to-list (& env-vec)))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two"
        "process env vec order")
      (assert-process-env-list2
        (& (process.command-env env-command))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two"
        "process command env vec order")
      (assert-process-env-list2
        (& (process.env-vec-to-list (& env-dup)))
        "TL_DUP"
        "first"
        "TL_DUP"
        "second"
        "process env vec duplicate order")
      (assert-process-env-validation
        (process.env-vec-validation-error (& bad-empty))
        "process: environment variable name is empty"
        "process env vec empty name")
      (assert-process-env-validation
        (process.env-vec-validation-error (& bad-name))
        "process: environment variable name contains '='"
        "process env vec bad name")
      (assert-process-env-validation
        (process.env-vec-validation-error (& bad-shape))
        "process: environment vector name/value counts differ"
        "process env vec shape")
      (assert-process-env-validation
        (process.env-vec-validation-error (& bad-live-length))
        "process: environment vector storage is malformed"
        "process env vec forged live length")
      (assert-process-invalid-command
        (process.output
          (process.command-with-env-vec (clone command) (& bad-empty)))
        "process: environment variable name is empty")
      (assert-process-child-invalid-command
        (process.start
          (process.command-with-env-vec (clone command) (& bad-name)))
        "process: environment variable name contains '='"))
    (assert-process-no-string
      (process.command-cwd default-command)
      "process default cwd")
    (assert-process-invalid-command
      (process.output (process.command "" (process.args-empty)))
      "process: executable path is empty")
    (assert-process-invalid-command
      (process.output (process.command-with-cwd (clone command) ""))
      "process: cwd path is empty")
    (assert-process-invalid-command
      (process.output (process.command-with-env (clone command) "" "1"))
      "process: environment variable name is empty")
    (assert-process-invalid-command
      (process.output (process.command-with-env (clone command) "BAD=NAME" "1"))
      "process: environment variable name contains '='")
    (assert-process-invalid-command
      (process.output (process-api-malformed-env-command))
      "process: environment storage is malformed")
    (assert-process-invalid-command
      (process.output (process-api-oversized-argv-command))
      "process: argument storage limit exceeded")
    (assert-process-invalid-command
      (process.output
        (process.command (process-api-string-with-nul) (process.args-empty)))
      "process: executable path contains NUL")
    (assert-process-invalid-command
      (process.output
        (process.command
          "echo"
          (process.args-single (process-api-string-with-nul))))
      "process: argument contains NUL")
    (assert-process-invalid-command
      (process.output
        (process.command-with-cwd
          (process.command "echo" (process.args-empty))
          (process-api-string-with-nul)))
      "process: cwd path contains NUL")
    (assert-process-invalid-command
      (process.output
        (process.command-with-env
          (process.command "echo" (process.args-empty))
          (process-api-string-with-nul)
          "value"))
      "process: environment variable name contains NUL")
    (assert-process-invalid-command
      (process.output
        (process.command-with-env
          (process.command "echo" (process.args-empty))
          "TL_NUL_VALUE"
          (process-api-string-with-nul)))
      "process: environment variable value contains NUL")
    (test.assert-true
      (process.command-valid? nul-stdin-command)
      "process stdin preserves embedded NUL")
    (assert-process-child-invalid-command
      (process.start (process.command "" (process.args-empty)))
      "process: executable path is empty")
    (assert-process-child-invalid-command
      (process.start (process.command-with-cwd (clone command) ""))
      "process: cwd path is empty")
    (assert-process-child-invalid-command
      (process.start (process.command-with-env (clone command) "" "1"))
      "process: environment variable name is empty")
    (assert-process-child-invalid-command
      (process.start (process.command-with-env (clone command) "BAD=NAME" "1"))
      "process: environment variable name contains '='")
    (test.assert-true (process.command-valid? command) "process valid command")
    (test.assert-false
      (process.command-valid? invalid-command)
      "process invalid empty executable")
    (test.assert-true
      (process.result-success?
        (OkProcessOutput (process.ProcessOutput 0 "" "")))
      "process result success")
    (test.assert-false
      (process.result-success?
        (OkProcessOutput (process.ProcessOutput 7 "" "")))
      "process result nonzero")
    (test.assert-false
      (process.result-success?
        (ErrProcessOutput (ProcessSpawnFailed "spawn failed")))
      "process result error")
    (test.assert-true
      (process.error-spawn-failed? (ProcessSpawnFailed "spawn failed"))
      "process spawn predicate")
    (test.assert-true
      (process.error-wait-failed? (ProcessWaitFailed "wait failed"))
      "process wait predicate")
    (with
      ([started
          (process.OkProcessChild (process.ProcessChild (box 0)))
          process.cleanup-result-process-child])
      (test.assert-true
        (process.child-started? (& started))
        "process child started predicate"))
    (with
      ([unsupported
          (process.ErrProcessChild (ProcessUnsupported "unsupported"))
          process.cleanup-result-process-child])
      (test.assert-false
        (process.child-started? (& unsupported))
        "process child unsupported predicate"))
    42))