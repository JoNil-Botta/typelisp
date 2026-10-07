;; Exact child environments (#7547): child self-inspection through the real
;; execve / CreateProcess boundary. Inherited mode keeps a parent sentinel;
;; exact mode gives the child only its rows, including none.
(import stdlib.env)
(import stdlib.io)
(import stdlib.process)
(import stdlib.process_runtime)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)

(define (windows?) : bool
  (string.eq (env.path-list-separator) ";"))

;; The child's line ending.
(define (nl) : String
  (if (windows?)
    "\r\n"
    "\n"))

(define (assert-process-ok
  [result : process.ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [message : String]) : unit
  (match result
    [(OkProcessOutput output)
      (test.assert-i64-eq
        (process.output-status output)
        expected-status
        (string.copy (& message)))
      (test.assert-string-eq
        (& (process.output-stdout output))
        (& expected-stdout)
        message)]
    [(ErrProcessOutput error)
      (io.panic (str_cat.str-cat message ": " (process.error-message error)))]))

(define (assert-process-status
  [result : process.ResultProcessOutput]
  [expected-status : i64]
  [message : String]) : unit
  (test.assert-i64-eq
    (process.result-status-or result -1)
    expected-status
    message))

(define (assert-process-invalid
  [result : process.ResultProcessOutput]
  [expected-message : String]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (match error
        [(ProcessInvalidCommand actual)
          (test.assert-string-eq (& actual) (& expected-message) message)]
        [_ (io.panic message)])]
    [(OkProcessOutput _) (io.panic message)]))

;; Rows `TYPELISP_EXACT_B` then `TYPELISP_EXACT_A`, out of name order, then an
;; empty value.
(define (exact-rows) : process.ProcessEnvVec
  (let
    [rows : process.ProcessEnvVec (process.env-vec-new)]
    (process.env-vec-append! (&mut rows) "TYPELISP_EXACT_B" "two words")
    (process.env-vec-append! (&mut rows) "TYPELISP_EXACT_A" "1")
    (process.env-vec-append! (&mut rows) "TYPELISP_EXACT_EMPTY" "")
    rows))

(define (with-exact-rows [command : process.ProcessCommand]) : process.ProcessCommand
  (let
    [rows : process.ProcessEnvVec (exact-rows)]
    (process.command-with-exact-env-vec command (& rows))))

(define (with-no-rows [command : process.ProcessCommand]) : process.ProcessCommand
  (process.command-with-exact-env-list command (process.env-empty)))

;; The Linux environment dump and a Windows listing of this fixture's names.
(define (dump-command) : process.ProcessCommand
  (if (windows?)
    (process.command
      "C:\\Windows\\System32\\cmd.exe"
      (process.args-cons "/C" (process.args-single "set TYPELISP_EXACT_")))
    (process.command "/usr/bin/env" (process.args-empty))))

(define (sentinel-command) : process.ProcessCommand
  (if (windows?)
    (process.command
      "C:\\Windows\\System32\\cmd.exe"
      (process.args-cons
        "/C"
        (process.args-single "echo %TYPELISP_EXACT_SENTINEL%")))
    (process.command
      "/usr/bin/printenv"
      (process.args-single "TYPELISP_EXACT_SENTINEL"))))

;; Two rows naming one variable under the target's comparison.
(define (duplicate-rows-command [first : String] [second : String]) : process.ProcessCommand
  (process.command-with-exact-env
    (process.command-with-exact-env (dump-command) first "x")
    second
    "y"))

(define (assert-exact-children) : unit
  (let
    [rows-dump : String
      (if (windows?)
        (str_cat.str-cat
          "TYPELISP_EXACT_A=1"
          (nl)
          "TYPELISP_EXACT_B=two words"
          (nl)
          "TYPELISP_EXACT_EMPTY="
          (nl))
        "TYPELISP_EXACT_B=two words\nTYPELISP_EXACT_A=1\nTYPELISP_EXACT_EMPTY=\n")]
    (test.assert-true
      (env.set! "TYPELISP_EXACT_SENTINEL" "parent")
      "exact env sentinel set")
    (assert-process-ok
      (process.output (sentinel-command))
      0
      (str_cat.str-cat "parent" (nl))
      "inherited child sees the parent sentinel")
    (assert-process-ok
      (process.output
        (process.command-with-env (sentinel-command) "TYPELISP_EXACT_A" "1"))
      0
      (str_cat.str-cat "parent" (nl))
      "inherited overrides keep the parent sentinel")
    ;; Linux passes rows in row order; Windows sorts the block by name.
    (assert-process-ok
      (process.output (with-exact-rows (dump-command)))
      0
      (string.copy rows-dump)
      "exact child holds only its rows")
    (assert-process-ok
      (process.output (with-exact-rows (dump-command)))
      0
      (string.copy rows-dump)
      "exact child repeated invocation")
    (if (windows?)
      (begin
        (assert-process-ok
          (process.output (with-exact-rows (sentinel-command)))
          0
          (str_cat.str-cat "%TYPELISP_EXACT_SENTINEL%" (nl))
          "exact child does not see the parent sentinel")
        ;; `set` with no matching name exits 1 and lists nothing.
        (assert-process-status
          (process.output (with-no-rows (dump-command)))
          1
          "empty exact environment has no rows")
        (assert-process-invalid
          (process.output (duplicate-rows-command "Path" "PATH"))
          "process: exact environment repeats a variable name"
          "windows rejects case-colliding exact names"))
      (begin
        (assert-process-status
          (process.output (with-exact-rows (sentinel-command)))
          1
          "exact child does not see the parent sentinel")
        (assert-process-ok
          (process.output (with-no-rows (dump-command)))
          0
          ""
          "empty exact environment is empty")
        (assert-process-ok
          (process.output (duplicate-rows-command "Path" "PATH"))
          0
          "PATH=y\nPath=x\n"
          "linux keeps case-distinct exact names")
        ;; argv, cwd, stdin, inherit mode and async start are unchanged.
        (assert-process-ok
          (process.output
            (with-exact-rows
              (process.command
                "/usr/bin/printf"
                (process.args-cons
                  "%s:%s"
                  (process.args-cons "a" (process.args-single "b"))))))
          0
          "a:b"
          "exact env keeps argv")
        (assert-process-ok
          (process.output
            (with-exact-rows
              (process.command-with-cwd
                (process.command
                  "/usr/bin/test"
                  (process.args-cons "-f" (process.args-single "process.tl")))
                "stdlib")))
          0
          ""
          "exact env keeps cwd")
        (assert-process-ok
          (process.output
            (with-exact-rows
              (process.command-with-stdin
                (process.command "/usr/bin/cat" (process.args-empty))
                "stdin-under-exact-env")))
          0
          "stdin-under-exact-env"
          "exact env keeps stdin")
        (assert-process-status
          (process.inherit
            (with-no-rows
              (process.command "/usr/bin/false" (process.args-empty))))
          1
          "exact env keeps inherit-mode exit status")
        (with
          ([child
              (match (process.start (with-exact-rows (dump-command)))
                [(OkProcessChild child) child]
                [(ErrProcessChild error)
                  (io.panic
                    (str_cat.str-cat
                      "exact env async start: "
                      (process.error-message error)))])
              process.cleanup-process-child])
          (assert-process-ok
            (process.wait (&mut child))
            0
            (string.copy rows-dump)
            "exact env async start/wait"))))
    (assert-process-invalid
      (process.output
        (duplicate-rows-command "TYPELISP_EXACT_A" "TYPELISP_EXACT_A"))
      "process: exact environment repeats a variable name"
      "exact env rejects a repeated name")
    (test.assert-true
      (env.unset! "TYPELISP_EXACT_SENTINEL")
      "exact env sentinel unset")))

;; An unknown runtime policy code fails before spawn at every entry point.
(define (unknown-policy-command) : process_runtime.ProcessRuntimeCommand
  (process_runtime.command-full-with-env-policy
    "/definitely-missing-typelisp-7547"
    (process_runtime.args-empty)
    (process_runtime.no-string)
    (process_runtime.env-empty)
    7
    (process_runtime.no-string)))

(define (assert-unknown-policy-rejected) : unit
  (let
    [output : process.ResultProcessOutput
      (process.output-from-runtime
        (unsafe
          (process_runtime.tl_process_output (unknown-policy-command))))]
    [inherited : process.ResultProcessOutput
      (process.output-from-runtime
        (unsafe
          (process_runtime.tl_process_inherit (unknown-policy-command))))]
    (assert-process-invalid
      output
      "process: unsupported environment policy"
      "unknown policy output")
    (assert-process-invalid
      inherited
      "process: unsupported environment policy"
      "unknown policy inherit")
    (test.assert-string-eq
      (&
        (process.child-result-error-message-or
          (process.child-from-runtime
            (unsafe
              (process_runtime.tl_process_start (unknown-policy-command))))
          "<process-ok>"))
      "process: unsupported environment policy"
      "unknown policy start")))

;; The Windows block order: ASCII case folded, a prefix first, stable.
(define (assert-windows-order) : unit
  (let
    [env : process_runtime.ProcessRuntimeEnvList
      (process_runtime.env-cons
        "path"
        "1"
        (process_runtime.env-cons
          "ab"
          "2"
          (process_runtime.env-cons
            "A"
            "3"
            (process_runtime.env-cons
              "PATH"
              "4"
              (process_runtime.env-cons "_x" "5" (process_runtime.env-empty))))))]
    [order : (__tl_dyn-array i64) (process_runtime.env-windows-order (& env))]
    (test.assert-i64-eq (array-length order) 5 "windows order count")
    ;; A, ab, path, PATH (equal folded names keep row order), _x.
    (test.assert-i64-eq (array-ref order 0) 2 "windows order A")
    (test.assert-i64-eq (array-ref order 1) 1 "windows order ab")
    (test.assert-i64-eq (array-ref order 2) 0 "windows order path")
    (test.assert-i64-eq (array-ref order 3) 3 "windows order PATH")
    (test.assert-i64-eq (array-ref order 4) 4 "windows order _x")
    (test.assert-i64-eq
      (process_runtime.env-name-fold-compare "Path" "PATH")
      0
      "fold compare equal")
    (test.assert-true
      (< (process_runtime.env-name-fold-compare "PAT" "path") 0)
      "fold compare prefix first")
    (test.assert-i64-eq
      (array-length
        (process_runtime.env-windows-order (& (process_runtime.env-empty))))
      0
      "windows order empty")))

(define (main) : i64
  (assert-windows-order)
  (assert-unknown-policy-rejected)
  (assert-exact-children)
  42)