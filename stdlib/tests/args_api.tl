(import "stdlib/args.tl")
(import "stdlib/list.tl")
(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (args-api-specs) : ArgsOptionSpecList
  (args-option-spec-cons
    (args-value-option "output" "output" "o")
    (args-option-spec-cons
      (args-value-option "include" "include" "I")
      (args-option-spec-cons
        (args-flag-option "verbose" "verbose" "v")
        (args-option-spec-empty)))))

(define (args-api-array0) : (Array String)
  (make-array String 0))

(define (args-api-array1 [a : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 1)]
    (begin
      (array-set! items 0 a)
      items)))

(define (args-api-array2 [a : String] [b : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 2)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
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

(define (expect-ok [result : ResultArgsParsed] [message : String]) : ArgsParsed
  (match result
    [(OkArgsParsed parsed) parsed]
    [(ErrArgsParsed _) (panic message)]))

(define (expect-error [result : ResultArgsParsed] [message : String]) : ArgsError
  (match result
    [(OkArgsParsed _) (panic message)]
    [(ErrArgsParsed error) error]))

(define (assert-string-list-empty [items : StringList] [message : String]) : unit
  (match items
    [(StringNil) unit]
    [_ (panic message)]))

(define (assert-string-list2
  [items : StringList]
  [first : String]
  [second : String]
  [message : String]) : unit
  (match items
    [(StringCons a rest)
      (match (box-get rest)
        [(StringCons b tail)
          (match (box-get tail)
            [(StringNil)
              (begin
                (assert-owned-string-eq a first message)
                (assert-owned-string-eq b second message))]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-list3
  [items : StringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(StringCons a rest)
      (match (box-get rest)
        [(StringCons b more)
          (match (box-get more)
            [(StringCons c tail)
              (match (box-get tail)
                [(StringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (test-empty-argv) : unit
  (let
    [parsed : ArgsParsed
      (expect-ok
        (args-parse-array (args-api-specs) (args-api-array0))
        "empty argv should parse")]
    (begin
      (assert-string-list-empty
        (args-parsed-positionals parsed)
        "empty argv has no positionals")
      (assert-i64-eq
        (args-option-count parsed "verbose")
        0
        "empty argv has no flags"))))

(define (test-positionals-only) : unit
  (let
    [parsed : ArgsParsed
      (expect-ok
        (args-parse-array
          (args-api-specs)
          (args-api-array3 "src.tl" "out.s" "-"))
        "positional-only argv should parse")]
    (assert-string-list3
      (args-parsed-positionals parsed)
      "src.tl"
      "out.s"
      "-"
      "positionals preserve input order")))

(define (test-flags-around-positionals) : unit
  (let
    [parsed : ArgsParsed
      (expect-ok
        (args-parse-array
          (args-api-specs)
          (args-api-array5 "input.tl" "--verbose" "-o" "out.s" "rest"))
        "flags around positionals should parse")]
    (begin
      (assert-true
        (args-option-present? parsed "verbose")
        "long boolean flag present")
      (assert-i64-eq
        (args-option-count parsed "output")
        1
        "short value flag counted")
      (assert-owned-string-eq
        (args-option-value-or parsed "output" "missing")
        "out.s"
        "short value flag consumes next argv")
      (assert-string-list2
        (args-parsed-positionals parsed)
        "input.tl"
        "rest"
        "positionals before and after flags preserved"))))

(define (test-end-of-options) : unit
  (let
    [parsed : ArgsParsed
      (expect-ok
        (args-parse-array
          (args-api-specs)
          (args-api-array3 "--" "--verbose" "-o"))
        "end-of-options should parse")]
    (begin
      (assert-i64-eq
        (args-option-count parsed "verbose")
        0
        "options after -- are positionals")
      (assert-string-list2
        (args-parsed-positionals parsed)
        "--verbose"
        "-o"
        "-- preserves following tokens as positionals"))))

(define (test-missing-value) : unit
  (let
    [error : ArgsError
      (expect-error
        (args-parse-array (args-api-specs) (args-api-array1 "--output"))
        "missing value should fail")]
    (begin
      (assert-true (args-error-missing-value? error) "missing value error kind")
      (assert-owned-string-eq
        (args-error-option error)
        "--output"
        "missing value carries token"))))

(define (test-unknown-option) : unit
  (let
    [error : ArgsError
      (expect-error
        (args-parse-array (args-api-specs) (args-api-array1 "--missing"))
        "unknown option should fail")]
    (begin
      (assert-true
        (args-error-unknown-option? error)
        "unknown option error kind")
      (assert-owned-string-eq
        (args-error-option error)
        "--missing"
        "unknown option carries token"))))

(define (test-repeated-options) : unit
  (let
    [parsed : ArgsParsed
      (expect-ok
        (args-parse-array
          (args-api-specs)
          (args-api-array6 "-I" "inc1" "--include" "inc2" "-v" "-v"))
        "repeated options should parse")]
    (begin
      (assert-i64-eq
        (args-option-count parsed "include")
        2
        "repeated value option count")
      (assert-owned-string-eq
        (args-option-value-or parsed "include" "missing")
        "inc2"
        "last repeated value returned")
      (assert-i64-eq
        (args-option-count parsed "verbose")
        2
        "repeated boolean flag count"))))

(define (test-equals-spelling-unsupported) : unit
  (let
    [error : ArgsError
      (expect-error
        (args-parse-array (args-api-specs) (args-api-array1 "--output=file"))
        "equals spelling should be rejected in v1")]
    (begin
      (assert-true
        (args-error-unknown-option? error)
        "equals spelling is intentionally unknown")
      (assert-owned-string-eq
        (args-error-option error)
        "--output=file"
        "equals spelling carries original token"))))

(define (main) : i64
  (begin
    (test-empty-argv)
    (test-positionals-only)
    (test-flags-around-positionals)
    (test-end-of-options)
    (test-missing-value)
    (test-unknown-option)
    (test-repeated-options)
    (test-equals-spelling-unsupported)
    42))