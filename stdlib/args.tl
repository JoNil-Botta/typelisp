;# stdlib/args.tl - Reusable argv option parser (#2680).
;#
;# Parses a caller-provided argv string sequence against explicit option specs.
;# The v1 surface is intentionally small: boolean flags, value flags, repeated
;# options, positional preservation, and `--` end-of-options handling. It does
;# not implement subcommands, help rendering, shell tokenization, config files,
;# short-option clusters, or `--name=value`; those spellings are reported as
;# unknown options unless a spec names them literally.
;#
;# Result lists, positionals, error payload strings, and helper substrings are
;# ordinary active-arena allocations. No process execution or filesystem module
;# is involved; `args-parse-argv*` only reads the raw argv accessors from
;# `stdlib/io.tl`.
;#
;# Usage: `(import "stdlib/args.tl")`
;#
;# ```typelisp
;# (import "stdlib/args.tl")
;# (define specs : ArgsOptionSpecList
;#   (args-option-spec-cons
;#     (args-value-option "output" "output" "o")
;#     (args-option-spec-cons
;#       (args-flag-option "verbose" "verbose" "v")
;#       (args-option-spec-empty))))
;# (define (main) : i64
;#   (match (args-parse-argv specs 1)
;#     [(OkArgsParsed parsed)
;#       (if (args-option-present? parsed "verbose") 1 0)]
;#     [(ErrArgsParsed _) 2]))
;# ```
(import "io.tl")
(import "list.tl")
(import "string.tl")

;: Option arity: a boolean flag consumes no value, while a value flag consumes
;: the following argv string.
(defenum ArgsOptionArity
  (ArgsFlag)
  (ArgsValue))

;: One accepted option spelling. `name` is the canonical key stored in parsed
;: results; `long` omits the leading `--`, and `short` omits the leading `-`.
;: Use the empty string for an absent long or short spelling.
(defstruct ArgsOptionSpec
  (name String)
  (long String)
  (short String)
  (arity ArgsOptionArity))

;: Immutable list of option specs.
(defenum ArgsOptionSpecList
  (ArgsOptionSpecNil)
  (ArgsOptionSpecCons ArgsOptionSpec (Box ArgsOptionSpecList)))

;: One parsed option occurrence in input order. Boolean flags set `has-value`
;: false and store the empty string as `value`.
(defstruct ArgsOption
  (name String)
  (value String)
  (has-value bool))

;: Immutable list of parsed option occurrences.
(defenum ArgsOptionList
  (ArgsOptionNil)
  (ArgsOptionCons ArgsOption (Box ArgsOptionList)))

;: Parsed argv result: ordered option occurrences and ordered positionals.
(defstruct ArgsParsed
  (options ArgsOptionList)
  (positionals StringList))

;: Structured parse errors.
(defenum ArgsError
  (ArgsUnknownOption String)
  (ArgsMissingValue String))

;: Recoverable parse result.
(defenum ResultArgsParsed
  (OkArgsParsed ArgsParsed)
  (ErrArgsParsed ArgsError))

;: Optional spec result used by token lookup.
(defenum ArgsMaybeOptionSpec
  (ArgsNoOptionSpec)
  (ArgsSomeOptionSpec ArgsOptionSpec))

;: Internal parse accumulator. Lists are stored reversed until the final result
;: is produced.
(defstruct ArgsParseState
  (options ArgsOptionList)
  (positionals StringList)
  (stop-options bool))

;: Internal successful step result: next state plus next argv index.
(defstruct ArgsParseAdvance
  (state ArgsParseState)
  (next-index i64))

;: Internal recoverable step result.
(defenum ResultArgsParseAdvance
  (OkArgsParseAdvance ArgsParseAdvance)
  (ErrArgsParseAdvance ArgsError))

;: Return an empty option spec list.
(define (args-option-spec-empty) : ArgsOptionSpecList
  (ArgsOptionSpecNil))

;: Prepend `spec` to `rest`.
(define (args-option-spec-cons
  [spec : ArgsOptionSpec]
  [rest : ArgsOptionSpecList]) : ArgsOptionSpecList
  (ArgsOptionSpecCons spec (box rest)))

;: Construct a boolean flag spec.
(define (args-flag-option [name : String] [long : String] [short : String]) : ArgsOptionSpec
  (ArgsOptionSpec name long short (ArgsFlag)))

;: Construct a value-consuming flag spec.
(define (args-value-option [name : String] [long : String] [short : String]) : ArgsOptionSpec
  (ArgsOptionSpec name long short (ArgsValue)))

;: Return the canonical name for a spec.
(define (args-option-spec-name [spec : ArgsOptionSpec]) : String
  (struct-get spec name))

;: Return the long spelling for a spec, without leading dashes.
(define (args-option-spec-long [spec : ArgsOptionSpec]) : String
  (struct-get spec long))

;: Return the short spelling for a spec, without the leading dash.
(define (args-option-spec-short [spec : ArgsOptionSpec]) : String
  (struct-get spec short))

;: Return the arity for a spec.
(define (args-option-spec-arity [spec : ArgsOptionSpec]) : ArgsOptionArity
  (struct-get spec arity))

;: Return true when an arity consumes a following value.
(define (args-option-arity-value? [arity : ArgsOptionArity]) : bool
  (match arity
    [(ArgsFlag) false]
    [(ArgsValue) true]))

;: Return true when `spec` has the long spelling `name`.
(define (args-option-spec-matches-long? [spec : ArgsOptionSpec] [name : String]) : bool
  (and
    (not (string-eq (args-option-spec-long spec) ""))
    (string-eq (args-option-spec-long spec) name)))

;: Return true when `spec` has the short spelling `name`.
(define (args-option-spec-matches-short?
  [spec : ArgsOptionSpec]
  [name : String]) : bool
  (and
    (not (string-eq (args-option-spec-short spec) ""))
    (string-eq (args-option-spec-short spec) name)))

;: Return an empty parsed option list.
(define (args-option-list-empty) : ArgsOptionList
  (ArgsOptionNil))

;: Prepend one parsed option occurrence.
(define (args-option-list-cons [option : ArgsOption] [rest : ArgsOptionList]) : ArgsOptionList
  (ArgsOptionCons option (box rest)))

;: Return a parsed option occurrence's canonical name.
(define (args-option-name [option : ArgsOption]) : String
  (struct-get option name))

;: Return a parsed option occurrence's value, or the empty string for flags.
(define (args-option-value [option : ArgsOption]) : String
  (struct-get option value))

;: Return true when a parsed option occurrence carries a value.
(define (args-option-has-value? [option : ArgsOption]) : bool
  (struct-get option has-value))

;: Reverse parsed options onto `acc`, allocating a fresh list spine.
(define (args-option-list-reverse-onto
  [items : ArgsOptionList]
  [acc : ArgsOptionList]) : ArgsOptionList
  (match items
    [(ArgsOptionNil) acc]
    [(ArgsOptionCons head rest)
      (args-option-list-reverse-onto
        (box-get rest)
        (ArgsOptionCons head (box acc)))]))

;: Return options in reverse order.
(define (args-option-list-reverse [items : ArgsOptionList]) : ArgsOptionList
  (args-option-list-reverse-onto items (ArgsOptionNil)))

;: Count parsed option occurrences with the canonical `name`.
(define (args-option-list-count [items : ArgsOptionList] [name : String]) : i64
  (match items
    [(ArgsOptionNil) 0]
    [(ArgsOptionCons head rest)
      (+
        (if (string-eq (args-option-name head) name)
          1
          0)
        (args-option-list-count (box-get rest) name))]))

;: Return true when `items` contains at least one option with `name`.
(define (args-option-list-present? [items : ArgsOptionList] [name : String]) : bool
  (> (args-option-list-count items name) 0))

;: Return the last value carried by option `name`, or `fallback` when absent or
;: when only boolean flag occurrences are present.
(define (args-option-list-value-or
  [items : ArgsOptionList]
  [name : String]
  [fallback : String]) : String
  (match items
    [(ArgsOptionNil) fallback]
    [(ArgsOptionCons head rest)
      (args-option-list-value-or
        (box-get rest)
        name
        (if (and
          (string-eq (args-option-name head) name)
          (args-option-has-value? head))
          (args-option-value head)
          fallback))]))

;: Return the parsed option occurrence list.
(define (args-parsed-options [parsed : ArgsParsed]) : ArgsOptionList
  (struct-get parsed options))

;: Return the positional arguments in input order.
(define (args-parsed-positionals [parsed : ArgsParsed]) : StringList
  (struct-get parsed positionals))

;: Count option occurrences in a parsed result.
(define (args-option-count [parsed : ArgsParsed] [name : String]) : i64
  (args-option-list-count (args-parsed-options parsed) name))

;: Return true when a parsed result contains option `name`.
(define (args-option-present? [parsed : ArgsParsed] [name : String]) : bool
  (args-option-list-present? (args-parsed-options parsed) name))

;: Return the last parsed value for option `name`, or `fallback`.
(define (args-option-value-or
  [parsed : ArgsParsed]
  [name : String]
  [fallback : String]) : String
  (args-option-list-value-or (args-parsed-options parsed) name fallback))

;: Render a parse error as a diagnostic message.
(define (args-error-message [error : ArgsError]) : String
  (match error
    [(ArgsUnknownOption option) (string-append "args: unknown option " option)]
    [(ArgsMissingValue option)
      (string-append "args: missing value for " option)]))

;: Return true for unknown-option errors.
(define (args-error-unknown-option? [error : ArgsError]) : bool
  (match error
    [(ArgsUnknownOption _) true]
    [(ArgsMissingValue _) false]))

;: Return true for missing-value errors.
(define (args-error-missing-value? [error : ArgsError]) : bool
  (match error
    [(ArgsUnknownOption _) false]
    [(ArgsMissingValue _) true]))

;: Return the original option token carried by an error.
(define (args-error-option [error : ArgsError]) : String
  (match error
    [(ArgsUnknownOption option) option]
    [(ArgsMissingValue option) option]))

;: Return true when `token` is exactly `--`.
(define (args-end-of-options-token? [token : String]) : bool
  (string-eq token "--"))

;: Return true when `token` looks like an option token rather than a positional.
(define (args-option-looking-token? [token : String]) : bool
  (and (> (string-length token) 1) (char-eq (string-ref token 0) #-')))

;: Return true when `token` has the supported long spelling `--name`.
(define (args-long-token? [token : String]) : bool
  (and
    (> (string-length token) 2)
    (char-eq (string-ref token 0) #-')
    (char-eq (string-ref token 1) #-')))

;: Return true when `token` has the supported short spelling `-x`.
(define (args-short-token? [token : String]) : bool
  (and (= (string-length token) 2) (char-eq (string-ref token 0) #-')))

;: Return the long name portion of a supported long token.
(define (args-token-long-name [token : String]) : String
  (substring token 2 (- (string-length token) 2)))

;: Return the short name portion of a supported short token.
(define (args-token-short-name [token : String]) : String
  (substring token 1 1))

;: Find a spec by long spelling.
(define (args-find-spec-long [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (match specs
    [(ArgsOptionSpecNil) (ArgsNoOptionSpec)]
    [(ArgsOptionSpecCons spec rest)
      (if (args-option-spec-matches-long? spec name)
        (ArgsSomeOptionSpec spec)
        (args-find-spec-long (box-get rest) name))]))

;: Find a spec by short spelling.
(define (args-find-spec-short [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (match specs
    [(ArgsOptionSpecNil) (ArgsNoOptionSpec)]
    [(ArgsOptionSpecCons spec rest)
      (if (args-option-spec-matches-short? spec name)
        (ArgsSomeOptionSpec spec)
        (args-find-spec-short (box-get rest) name))]))

;: Find a matching spec for a supported option token.
(define (args-find-spec-token [specs : ArgsOptionSpecList] [token : String]) : ArgsMaybeOptionSpec
  (if (args-long-token? token)
    (args-find-spec-long specs (args-token-long-name token))
    (if (args-short-token? token)
      (args-find-spec-short specs (args-token-short-name token))
      (ArgsNoOptionSpec))))

;: Return a fresh empty parse state.
(define (args-parse-state-empty) : ArgsParseState
  (ArgsParseState (ArgsOptionNil) (StringNil) false))

;: Add a positional token to a parse state.
(define (args-parse-state-add-positional
  [state : ArgsParseState]
  [value : String]) : ArgsParseState
  (ArgsParseState
    (struct-get state options)
    (StringCons value (box (struct-get state positionals)))
    (struct-get state stop-options)))

;: Add a parsed option occurrence to a parse state.
(define (args-parse-state-add-option
  [state : ArgsParseState]
  [name : String]
  [value : String]
  [has-value : bool]) : ArgsParseState
  (ArgsParseState
    (ArgsOptionCons
      (ArgsOption name value has-value)
      (box (struct-get state options)))
    (struct-get state positionals)
    (struct-get state stop-options)))

;: Mark the parse state as past `--`.
(define (args-parse-state-stop-options [state : ArgsParseState]) : ArgsParseState
  (ArgsParseState
    (struct-get state options)
    (struct-get state positionals)
    true))

;: Convert the reversed parse state into the public ordered result.
(define (args-parse-state-finish [state : ArgsParseState]) : ArgsParsed
  (ArgsParsed
    (args-option-list-reverse (struct-get state options))
    (string-list-reverse (struct-get state positionals))))

;: Advance past one positional token.
(define (args-advance-positional
  [state : ArgsParseState]
  [current : String]
  [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance
      (args-parse-state-add-positional state current)
      (+ index 1))))

;: Advance past `--`.
(define (args-advance-end-of-options [state : ArgsParseState] [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance (args-parse-state-stop-options state) (+ index 1))))

;: Advance past a known option token, consuming a value when the spec requires
;: one.
(define (args-advance-known-option
  [state : ArgsParseState]
  [spec : ArgsOptionSpec]
  [current : String]
  [next-value : String]
  [has-next : bool]
  [index : i64]) : ResultArgsParseAdvance
  (if (args-option-arity-value? (args-option-spec-arity spec))
    (if has-next
      (OkArgsParseAdvance
        (ArgsParseAdvance
          (args-parse-state-add-option
            state
            (args-option-spec-name spec)
            next-value
            true)
          (+ index 2)))
      (ErrArgsParseAdvance (ArgsMissingValue current)))
    (OkArgsParseAdvance
      (ArgsParseAdvance
        (args-parse-state-add-option
          state
          (args-option-spec-name spec)
          ""
          false)
        (+ index 1)))))

;: Parse one token from a sequence.
(define (args-parse-step
  [specs : ArgsOptionSpecList]
  [state : ArgsParseState]
  [current : String]
  [next-value : String]
  [has-next : bool]
  [index : i64]) : ResultArgsParseAdvance
  (if (struct-get state stop-options)
    (args-advance-positional state current index)
    (if (args-end-of-options-token? current)
      (args-advance-end-of-options state index)
      (if (args-option-looking-token? current)
        (match (args-find-spec-token specs current)
          [(ArgsNoOptionSpec) (ErrArgsParseAdvance (ArgsUnknownOption current))]
          [(ArgsSomeOptionSpec spec)
            (args-advance-known-option
              state
              spec
              current
              next-value
              has-next
              index)])
        (args-advance-positional state current index)))))

;: Clamp a sequence start index to zero.
(define (args-clamp-start [start : i64]) : i64
  (if (< start 0)
    0
    start))

;: Clamp an exclusive end index into `[0, limit]`.
(define (args-clamp-end [end : i64] [limit : i64]) : i64
  (let
    [non-negative : i64
      (if (< end 0)
        0
        end)]
    (if (> non-negative limit)
      limit
      non-negative)))

;: Parse the array range `[index, end)` with `state`.
(define (args-parse-array-loop
  [specs : ArgsOptionSpecList]
  [argv : (Array String)]
  [index : i64]
  [end : i64]
  [state : ArgsParseState]) : ResultArgsParsed
  (if (>= index end)
    (OkArgsParsed (args-parse-state-finish state))
    (let
      [current : String (array-ref argv index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (array-ref argv (+ index 1))
          "")]
      (match (args-parse-step specs state current next-value has-next index)
        [(ErrArgsParseAdvance error) (ErrArgsParsed error)]
        [(OkArgsParseAdvance advance)
          (args-parse-array-loop
            specs
            argv
            (struct-get advance next-index)
            end
            (struct-get advance state))]))))

;: Parse the array range `[start, end)`. Negative bounds clamp to zero and end
;: clamps to the array length.
(define (args-parse-array-range
  [specs : ArgsOptionSpecList]
  [argv : (Array String)]
  [start : i64]
  [end : i64]) : ResultArgsParsed
  (let
    [limit : i64 (array-length argv)]
    [first : i64 (args-clamp-start start)]
    [last : i64 (args-clamp-end end limit)]
    (args-parse-array-loop specs argv first last (args-parse-state-empty))))

;: Parse the full argv array.
(define (args-parse-array [specs : ArgsOptionSpecList] [argv : (Array String)]) : ResultArgsParsed
  (args-parse-array-range specs argv 0 (array-length argv)))

;: Parse process argv range `[index, end)` with `state`.
(define (args-parse-argv-loop
  [specs : ArgsOptionSpecList]
  [index : i64]
  [end : i64]
  [state : ArgsParseState]) : ResultArgsParsed
  (if (>= index end)
    (OkArgsParsed (args-parse-state-finish state))
    (let
      [current : String (arg index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (arg (+ index 1))
          "")]
      (match (args-parse-step specs state current next-value has-next index)
        [(ErrArgsParseAdvance error) (ErrArgsParsed error)]
        [(OkArgsParseAdvance advance)
          (args-parse-argv-loop
            specs
            (struct-get advance next-index)
            end
            (struct-get advance state))]))))

;: Parse the process argv range `[start, end)`. Negative bounds clamp to zero
;: and end clamps to `(arg-count)`.
(define (args-parse-argv-range
  [specs : ArgsOptionSpecList]
  [start : i64]
  [end : i64]) : ResultArgsParsed
  (let
    [limit : i64 (arg-count)]
    [first : i64 (args-clamp-start start)]
    [last : i64 (args-clamp-end end limit)]
    (args-parse-argv-loop specs first last (args-parse-state-empty))))

;: Parse process argv from `start` through `(arg-count)`.
(define (args-parse-argv [specs : ArgsOptionSpecList] [start : i64]) : ResultArgsParsed
  (args-parse-argv-range specs start (arg-count)))

;: Inline test assertion for boolean predicates.
(define (args-test-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (panic message)))

;: Inline test assertion for `i64` equality.
(define (args-test-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (args-test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (args-test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (args-test-assert-true (string-eq actual expected) message))

;: Build the option specs used by argv parser inline tests.
(define (args-test-specs) : ArgsOptionSpecList
  (args-option-spec-cons
    (args-value-option "output" "output" "o")
    (args-option-spec-cons
      (args-value-option "include" "include" "I")
      (args-option-spec-cons
        (args-flag-option "verbose" "verbose" "v")
        (args-option-spec-empty)))))

;: Build a zero-length argv array for inline tests.
(define (args-test-array0) : (Array String)
  (make-array String 0))

;: Build a one-item argv array for inline tests.
(define (args-test-array1 [a : String]) : (Array String)
  (let
    [items : (Array String) (make-array String 1)]
    (begin
      (array-set! items 0 a)
      items)))

;: Build a three-item argv array for inline tests.
(define (args-test-array3 [a : String] [b : String] [c : String]) : (Array
    String)
  (let
    [items : (Array String) (make-array String 3)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
      (array-set! items 2 c)
      items)))

;: Build a five-item argv array for inline tests.
(define (args-test-array5
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

;: Build a six-item argv array for inline tests.
(define (args-test-array6
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

;: Unwrap a successful argv parse result for inline tests.
(define (args-test-expect-ok [result : ResultArgsParsed] [message : String]) : ArgsParsed
  (match result
    [(OkArgsParsed parsed) parsed]
    [(ErrArgsParsed _) (panic message)]))

;: Unwrap a failed argv parse result for inline tests.
(define (args-test-expect-error [result : ResultArgsParsed] [message : String]) : ArgsError
  (match result
    [(OkArgsParsed _) (panic message)]
    [(ErrArgsParsed error) error]))

;: Assert that a string list is empty.
(define (args-test-assert-string-list-empty
  [items : StringList]
  [message : String]) : unit
  (match items
    [(StringNil) unit]
    [_ (panic message)]))

;: Assert that a string list contains exactly two strings.
(define (args-test-assert-string-list2
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
                (args-test-assert-owned-string-eq a first message)
                (args-test-assert-owned-string-eq b second message))]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

;: Assert that a string list contains exactly three strings.
(define (args-test-assert-string-list3
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
                    (args-test-assert-owned-string-eq a first message)
                    (args-test-assert-owned-string-eq b second message)
                    (args-test-assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

;: Exercise an empty argv sequence.
(define (args-test-empty-argv) : unit
  (let
    [parsed : ArgsParsed
      (args-test-expect-ok
        (args-parse-array (args-test-specs) (args-test-array0))
        "empty argv should parse")]
    (begin
      (args-test-assert-string-list-empty
        (args-parsed-positionals parsed)
        "empty argv has no positionals")
      (args-test-assert-i64-eq
        (args-option-count parsed "verbose")
        0
        "empty argv has no flags"))))

;: Exercise positional-only argv parsing.
(define (args-test-positionals-only) : unit
  (let
    [parsed : ArgsParsed
      (args-test-expect-ok
        (args-parse-array
          (args-test-specs)
          (args-test-array3 "src.tl" "out.s" "-"))
        "positional-only argv should parse")]
    (args-test-assert-string-list3
      (args-parsed-positionals parsed)
      "src.tl"
      "out.s"
      "-"
      "positionals preserve input order")))

;: Exercise options interleaved with positionals.
(define (args-test-flags-around-positionals) : unit
  (let
    [parsed : ArgsParsed
      (args-test-expect-ok
        (args-parse-array
          (args-test-specs)
          (args-test-array5 "input.tl" "--verbose" "-o" "out.s" "rest"))
        "flags around positionals should parse")]
    (begin
      (args-test-assert-true
        (args-option-present? parsed "verbose")
        "long boolean flag present")
      (args-test-assert-i64-eq
        (args-option-count parsed "output")
        1
        "short value flag counted")
      (args-test-assert-owned-string-eq
        (args-option-value-or parsed "output" "missing")
        "out.s"
        "short value flag consumes next argv")
      (args-test-assert-string-list2
        (args-parsed-positionals parsed)
        "input.tl"
        "rest"
        "positionals before and after flags preserved"))))

;: Exercise `--` end-of-options handling.
(define (args-test-end-of-options) : unit
  (let
    [parsed : ArgsParsed
      (args-test-expect-ok
        (args-parse-array
          (args-test-specs)
          (args-test-array3 "--" "--verbose" "-o"))
        "end-of-options should parse")]
    (begin
      (args-test-assert-i64-eq
        (args-option-count parsed "verbose")
        0
        "options after -- are positionals")
      (args-test-assert-string-list2
        (args-parsed-positionals parsed)
        "--verbose"
        "-o"
        "-- preserves following tokens as positionals"))))

;: Exercise missing-value diagnostics.
(define (args-test-missing-value) : unit
  (let
    [error : ArgsError
      (args-test-expect-error
        (args-parse-array (args-test-specs) (args-test-array1 "--output"))
        "missing value should fail")]
    (begin
      (args-test-assert-true
        (args-error-missing-value? error)
        "missing value error kind")
      (args-test-assert-owned-string-eq
        (args-error-option error)
        "--output"
        "missing value carries token"))))

;: Exercise unknown-option diagnostics.
(define (args-test-unknown-option) : unit
  (let
    [error : ArgsError
      (args-test-expect-error
        (args-parse-array (args-test-specs) (args-test-array1 "--missing"))
        "unknown option should fail")]
    (begin
      (args-test-assert-true
        (args-error-unknown-option? error)
        "unknown option error kind")
      (args-test-assert-owned-string-eq
        (args-error-option error)
        "--missing"
        "unknown option carries token"))))

;: Exercise repeated short and long options.
(define (args-test-repeated-options) : unit
  (let
    [parsed : ArgsParsed
      (args-test-expect-ok
        (args-parse-array
          (args-test-specs)
          (args-test-array6 "-I" "inc1" "--include" "inc2" "-v" "-v"))
        "repeated options should parse")]
    (begin
      (args-test-assert-i64-eq
        (args-option-count parsed "include")
        2
        "repeated value option count")
      (args-test-assert-owned-string-eq
        (args-option-value-or parsed "include" "missing")
        "inc2"
        "last repeated value returned")
      (args-test-assert-i64-eq
        (args-option-count parsed "verbose")
        2
        "repeated boolean flag count"))))

;: Exercise intentionally unsupported `--name=value` spelling.
(define (args-test-equals-spelling-unsupported) : unit
  (let
    [error : ArgsError
      (args-test-expect-error
        (args-parse-array (args-test-specs) (args-test-array1 "--output=file"))
        "equals spelling should be rejected in v1")]
    (begin
      (args-test-assert-true
        (args-error-unknown-option? error)
        "equals spelling is intentionally unknown")
      (args-test-assert-owned-string-eq
        (args-error-option error)
        "--output=file"
        "equals spelling carries original token"))))

(test
  args-api
  (begin
    (args-test-empty-argv)
    (args-test-positionals-only)
    (args-test-flags-around-positionals)
    (args-test-end-of-options)
    (args-test-missing-value)
    (args-test-unknown-option)
    (args-test-repeated-options)
    (args-test-equals-spelling-unsupported)
    unit))