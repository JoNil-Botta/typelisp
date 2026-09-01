(import stdlib.args)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define args-api-specs : args.ArgsOptionSpecList
  (args.option-spec-cons
    (args.value-option "output" "output" "o")
    (args.option-spec-cons
      (args.value-option "include" "include" "I")
      (args.option-spec-cons
        (args.flag-option "verbose" "verbose" "v")
        (args.option-spec-empty)))))

(define (args-api-specs-shared-view) : args.ArgsOptionSpecList
  (unsafe
    (ptr-read (ptr-addr-of args-api-specs))))

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
  (args-api-assert-true (string.eq actual expected) message))

(define (args-api-vec0) : svec.Vec
  (svec.new))

(define (args-api-vec1 [a : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut items) a)
      items)))

(define (args-api-vec3 [a : String] [b : String] [c : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut items) a)
      (svec.push-ref! (&mut items) b)
      (svec.push-ref! (&mut items) c)
      items)))

(define (args-api-vec5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut items) a)
      (svec.push-ref! (&mut items) b)
      (svec.push-ref! (&mut items) c)
      (svec.push-ref! (&mut items) d)
      (svec.push-ref! (&mut items) e)
      items)))

(define (args-api-vec6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut items) a)
      (svec.push-ref! (&mut items) b)
      (svec.push-ref! (&mut items) c)
      (svec.push-ref! (&mut items) d)
      (svec.push-ref! (&mut items) e)
      (svec.push-ref! (&mut items) f)
      items)))

(define (args-api-parse-vec [specs : args.ArgsOptionSpecList] [argv : svec.Vec]) : args.ResultArgsParsed
  (args.parse-vec specs (& argv)))

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

(define (args-api-assert-vec-empty
  [items : (& items svec.Vec)]
  [message : String]) : unit
  (args-api-assert-i64-eq (svec.len items) 0 message))

(define (args-api-assert-vec2
  [items : (& items svec.Vec)]
  [first : String]
  [second : String]
  [message : String]) : unit
  (begin
    (args-api-assert-i64-eq (svec.len items) 2 (string.copy message))
    (args-api-assert-string-eq
      (svec.get items 0 "")
      first
      (string.copy message))
    (args-api-assert-string-eq (svec.get items 1 "") second message)))

(define (args-api-assert-vec3
  [items : (& items svec.Vec)]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (args-api-assert-i64-eq (svec.len items) 3 (string.copy message))
    (args-api-assert-string-eq
      (svec.get items 0 "")
      first
      (string.copy message))
    (args-api-assert-string-eq
      (svec.get items 1 "")
      second
      (string.copy message))
    (args-api-assert-string-eq (svec.get items 2 "") third message)))

(test
  args-api-empty-argv
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args-api-parse-vec (args-api-specs-shared-view) (args-api-vec0))
        "empty argv should parse")]
    (begin
      (args-api-assert-vec-empty
        (args.parsed-positionals (& parsed))
        "empty argv has no positionals")
      (args-api-assert-i64-eq
        (args.option-count parsed "verbose")
        0
        "empty argv has no flags"))))

(test
  args-api-positionals-only
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec3 "src.tl" "out.s" "-"))
        "positional-only argv should parse")]
    (args-api-assert-vec3
      (args.parsed-positionals (& parsed))
      "src.tl"
      "out.s"
      "-"
      "positionals preserve input order")))

(test
  args-api-flags-around-positionals
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec5 "input.tl" "--verbose" "-o" "out.s" "rest"))
        "flags around positionals should parse")]
    (begin
      (args-api-assert-true
        (args.option-present? parsed "verbose")
        "long boolean flag present")
      (args-api-assert-i64-eq
        (args.option-count parsed "output")
        1
        "short value flag counted")
      (args-api-assert-string-eq
        (args.option-value-or parsed "output" "missing")
        "out.s"
        "short value flag consumes next argv")
      (args-api-assert-vec2
        (args.parsed-positionals (& parsed))
        "input.tl"
        "rest"
        "positionals before and after flags preserved"))))

(test
  args-api-end-of-options
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec3 "--" "--verbose" "-o"))
        "end-of-options should parse")]
    (begin
      (args-api-assert-i64-eq
        (args.option-count parsed "verbose")
        0
        "tokens after -- are positionals")
      (args-api-assert-vec2
        (args.parsed-positionals (& parsed))
        "--verbose"
        "-o"
        "end-of-options preserves later tokens"))))

(test
  args-api-missing-value
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec1 "--output"))
        "missing value should fail")]
    (begin
      (args-api-assert-true
        (args.error-missing-value? error)
        "missing value error kind")
      (args-api-assert-string-eq
        (args.error-option error)
        "--output"
        "missing value carries token"))))

(test
  args-api-unknown-option
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec1 "--missing"))
        "unknown option should fail")]
    (begin
      (args-api-assert-true
        (args.error-unknown-option? error)
        "unknown option error kind")
      (args-api-assert-string-eq
        (args.error-option error)
        "--missing"
        "unknown option carries token"))))

(test
  args-api-repeated-options
  (let
    [parsed : args.ArgsParsed
      (args-api-expect-ok
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec6 "-I" "inc1" "--include" "inc2" "-v" "-v"))
        "repeated options should parse")]
    (begin
      (args-api-assert-i64-eq
        (args.option-count parsed "include")
        2
        "repeated value option count")
      (args-api-assert-string-eq
        (args.option-value-or parsed "include" "missing")
        "inc2"
        "last repeated value returned")
      (args-api-assert-i64-eq
        (args.option-count parsed "verbose")
        2
        "repeated boolean flag count"))))

(test
  args-api-equals-spelling-unsupported
  (let
    [error : args.ArgsError
      (args-api-expect-error
        (args-api-parse-vec
          (args-api-specs-shared-view)
          (args-api-vec1 "--output=file"))
        "equals spelling should be rejected in v1")]
    (begin
      (args-api-assert-true
        (args.error-unknown-option? error)
        "equals spelling is intentionally unknown")
      (args-api-assert-string-eq
        (args.error-option error)
        "--output=file"
        "equals spelling carries original token"))))