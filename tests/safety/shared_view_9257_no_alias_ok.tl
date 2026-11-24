;; #9257: Legitimate uses across stdlib modules return independent copies or
;; tracked borrows without aliasing, and `vector.copy-range!` works inside
;; explicit `unsafe`.
(import stdlib.args)
(import stdlib.json)
(import stdlib.msvc)
(import stdlib.process)
(import stdlib.process_borrowed)
(import stdlib.serialize)
(import stdlib.string)
(import stdlib.text_buf_borrowed)
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct Sample
  (label String)
  (items (Array i64 2)))

(import (serialize.serialize json Sample) as sample_json)

(define (main) : i64
  (let
    ;; 1. `process` accessors return independent copies: mutating the returned
    ;; `ProcessEnvList` or `ProcessStringList` cannot mutate the original owner.
    [env : process.ProcessEnvList
      (process.env-cons
        "B"
        "two"
        (process.env-cons "A" "one" (process.env-empty)))]
    [step : process.ProcessEnvStep (process.env-step env)]
    [rest : process.ProcessEnvList (process.env-step-rest (& step))]
    [step-ref (& step)]
    (set! (array-ref rest.values 0) "changed")
    (when
      (not (string.eq (& (array-ref step-ref.rest.values 0)) "one"))
      (return 1))
    (let
      [cmd : process.ProcessCommand
        (process.command-with-env
          (process.command "echo" (process.args-single "arg0"))
          "K"
          "v0")]
      [cmd-env : process.ProcessEnvList (process.command-env (& cmd))]
      [cmd-argv : process.ProcessStringList (process.command-argv (& cmd))]
      [cmd-ref (& cmd)]
      (set! (array-ref cmd-env.values 0) "mutated")
      (set! (array-ref cmd-argv.slots 0) "mutated")
      (when
        (not (string.eq (& (array-ref cmd-ref.env.values 0)) "v0"))
        (return 2))
      (when
        (not (string.eq (& (array-ref cmd-ref.argv.slots 0)) "arg0"))
        (return 3)))
    ;; 2. `process_borrowed` clones spines safely without aliasing or copying bytes.
    (let
      [exe : String "echo"]
      [arg : String "hello"]
      [bcmd : (process_borrowed.ProcessBorrowedCommand exe arg exe exe exe)
        (process_borrowed.command
          (& exe)
          (process_borrowed.args-single (& arg)))]
      [bargs : (process_borrowed.ProcessBorrowedStringList arg)
        (process_borrowed.command-argv (& bcmd))]
      (when
        (not (string.eq (process_borrowed.args-ref (& bargs) 0) (& arg)))
        (return 4)))
    ;; 3. `args` and `msvc` string accessors return owned copies.
    (let
      [spec : args.ArgsOptionSpec (args.flag-option "verbose" "verbose" "v")]
      [tool : msvc.MsvcTool (msvc.MsvcTool "link.exe" "p" "l" "i")]
      (when
        (not (string.eq (args.option-spec-name (& spec)) "verbose"))
        (return 5))
      (when
        (not (string.eq (msvc.tool-executable (& tool)) "link.exe"))
        (return 6)))
    ;; 4. `json` + `serialize` encode/decode without any shared-view macros.
    (let
      [sample : Sample (Sample "ok" (array 7 9))]
      [encoded : json.Json (sample_json.to-json sample)]
      (match (sample_json.from-json encoded)
        [(Ok decoded)
          (when
            (not
              (and
                (string.eq (& decoded.label) "ok")
                (= (array-ref decoded.items 0) 7)
                (= (array-ref decoded.items 1) 9)))
            (return 7))]
        [(Err _) (return 8)]))
    ;; 5. `text_buf_borrowed.clone-text-buf-borrowed` forks safely.
    (let
      [src : String "hi"]
      [base : (text_buf_borrowed.TextBufBorrowed src)
        (text_buf_borrowed.single (& src))]
      [fork : (text_buf_borrowed.TextBufBorrowed src)
        (text_buf_borrowed.append-owned
          (text_buf_borrowed.clone-text-buf-borrowed (& base))
          "!")]
      (when (not (string.eq (text_buf_borrowed.render fork) "hi!")) (return 9))
      (when (not (string.eq (text_buf_borrowed.render base) "hi")) (return 10)))
    ;; 6. `vector.copy-range!` works inside explicit `unsafe`.
    (let
      [v : ivec.Vec (ivec.new)]
      [dst : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      (ivec.push-ref! (&mut v) 19)
      (ivec.push-ref! (&mut v) 23)
      (unsafe
        (ivec.copy-range! (&mut dst) (__tl_array-data v.slots) 0 2))
      (if (= (+ (array-ref dst 0) (array-ref dst 1)) 42)
        42
        11))))