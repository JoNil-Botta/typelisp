(import stdlib.args)
(import stdlib.io)
(import stdlib.list)
(import stdlib.string)

(define args-api-specs : args.ArgsOptionSpecList
  (args.args-option-spec-cons
    (args.args-value-option "output" "output" "o")
    (args.args-option-spec-cons
      (args.args-value-option "include" "include" "I")
      (args.args-option-spec-cons
        (args.args-flag-option "verbose" "verbose" "v")
        (args.args-option-spec-empty)))))

(define (args-api-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (args-api-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (args-api-assert-true (= actual expected) message))

(define (args-api-assert-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (args-api-assert-true (string.string-eq actual expected) message))

(define (args-api-array0) : (Array String)
  (make-array String 0))

(define (args-api-array1 [a : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 1)]
    (begin
      (array-set! items 0 a)
      items)))

(define (args-api-array3 [a : String] [b : String] [c : String]) : (Array
    String)
  (let
    [items : (Array String) (make-array String 3)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
      (array-set! items 2 c)
      items)))

(define (args-api-array5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 5)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
      (array-set! items 2 c)
      (array-set! items 3 d)
      (array-set! items 4 e)
      items)))

(define (args-api-array6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 6)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
      (array-set! items 2 c)
      (array-set! items 3 d)
      (array-set! items 4 e)
      (array-set! items 5 f)
      items)))

(define (args-api-expect-ok [result : args.ResultArgsParsed] [message : String]) : args.ArgsParsed
  (match result
    [(args.OkArgsParsed parsed) parsed]
    [(args.ErrArgsParsed _) (io.panic message)]))

(define (args-api-expect-error
  [result : args.ResultArgsParsed]
  [message : String]) : args.ArgsError
  (match result
    [(args.OkArgsParsed _) (io.panic message)]
    [(args.ErrArgsParsed error) error]))

(define (args-api-assert-list-empty
  [items : list.StringList]
  [message : String]) : unit
  (args-api-assert-i64-eq (list.string-list-count items) 0 message))

(define (args-api-assert-list2
  [items : list.StringList]
  [first : String]
  [second : String]
  [message : String]) : unit
  (let
    [values : (Array String) (list.string-list-to-array items)]
    (begin
      (args-api-assert-i64-eq (array-length values) 2 message)
      (args-api-assert-string-eq (array-ref values 0) first message)
      (args-api-assert-string-eq (array-ref values 1) second message))))

(define (args-api-assert-list3
  [items : list.StringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (let
    [values : (Array String) (list.string-list-to-array items)]
    (begin
      (args-api-assert-i64-eq (array-length values) 3 message)
      (args-api-assert-string-eq (array-ref values 0) first message)
      (args-api-assert-string-eq (array-ref values 1) second message)
      (args-api-assert-string-eq (array-ref values 2) third message))))

(test
  args-api-empty-argv
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args.args-parse-array args-api-specs (args-api-array0))
        "empty argv should parse")]
    (begin
      (args-api-assert-list-empty
        (args.args-parsed-positionals parsed)
        "empty argv has no positionals")
      (args-api-assert-i64-eq
        (args.args-option-count parsed "verbose")
        0
        "empty argv has no flags"))))

(test
  args-api-positionals-only
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args.args-parse-array
          args-api-specs
          (args-api-array3 "src.tl" "out.s" "-"))
        "positional-only argv should parse")]
    (args-api-assert-list3
      (args.args-parsed-positionals parsed)
      "src.tl"
      "out.s"
      "-"
      "positionals preserve input order")))

(test
  args-api-flags-around-positionals
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args.args-parse-array
          args-api-specs
          (args-api-array5 "input.tl" "--verbose" "-o" "out.s" "rest"))
        "flags around positionals should parse")]
    (begin
      (args-api-assert-true
        (args.args-option-present? parsed "verbose")
        "long boolean flag present")
      (args-api-assert-i64-eq
        (args.args-option-count parsed "output")
        1
        "short value flag counted")
      (args-api-assert-string-eq
        (args.args-option-value-or parsed "output" "missing")
        "out.s"
        "short value flag consumes next argv")
      (args-api-assert-list2
        (args.args-parsed-positionals parsed)
        "input.tl"
        "rest"
        "positionals before and after flags preserved"))))

(test
  args-api-end-of-options
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args.args-parse-array
          args-api-specs
          (args-api-array3 "--" "--verbose" "-o"))
        "end-of-options should parse")]
    (begin
      (args-api-assert-i64-eq
        (args.args-option-count parsed "verbose")
        0
        "tokens after -- are positionals")
      (args-api-assert-list2
        (args.args-parsed-positionals parsed)
        "--verbose"
        "-o"
        "end-of-options preserves later tokens"))))

(test
  args-api-missing-value
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args.args-parse-array args-api-specs (args-api-array1 "--output"))
        "missing value should fail")]
    (begin
      (args-api-assert-true
        (args.args-error-missing-value? error)
        "missing value error kind")
      (args-api-assert-string-eq
        (args.args-error-option error)
        "--output"
        "missing value carries token"))))

(test
  args-api-unknown-option
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args.args-parse-array args-api-specs (args-api-array1 "--missing"))
        "unknown option should fail")]
    (begin
      (args-api-assert-true
        (args.args-error-unknown-option? error)
        "unknown option error kind")
      (args-api-assert-string-eq
        (args.args-error-option error)
        "--missing"
        "unknown option carries token"))))

(test
  args-api-repeated-options
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args.args-parse-array
          args-api-specs
          (args-api-array6 "-I" "inc1" "--include" "inc2" "-v" "-v"))
        "repeated options should parse")]
    (begin
      (args-api-assert-i64-eq
        (args.args-option-count parsed "include")
        2
        "repeated value option count")
      (args-api-assert-string-eq
        (args.args-option-value-or parsed "include" "missing")
        "inc2"
        "last repeated value returned")
      (args-api-assert-i64-eq
        (args.args-option-count parsed "verbose")
        2
        "repeated boolean flag count"))))

(test
  args-api-equals-spelling-unsupported
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args.args-parse-array args-api-specs (args-api-array1 "--output=file"))
        "equals spelling should be rejected in v1")]
    (begin
      (args-api-assert-true
        (args.args-error-unknown-option? error)
        "equals spelling is intentionally unknown")
      (args-api-assert-string-eq
        (args.args-error-option error)
        "--output=file"
        "equals spelling carries original token"))))