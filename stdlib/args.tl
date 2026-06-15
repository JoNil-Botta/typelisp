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
;# Usage: `(import stdlib.args)`
;#
;# ```typelisp
;# (import stdlib.args)
;# (define specs : args.ArgsOptionSpecList
;#   (args.args-option-spec-cons
;#     (args.args-value-option "output" "output" "o")
;#     (args.args-option-spec-cons
;#       (args.args-flag-option "verbose" "verbose" "v")
;#       (args.args-option-spec-empty))))
;# (define (main) : i64
;#   (match (args.args-parse-argv specs 1)
;#     [(args.OkArgsParsed parsed)
;#       (if (args.args-option-present? parsed "verbose") 1 0)]
;#     [(args.ErrArgsParsed _) 2]))
;# ```
(module stdlib.args)

(import stdlib.io as io_mod)

(import stdlib.list as list_mod)

(import stdlib.string as string_mod)

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
  (positionals list_mod.StringList))

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
  (positionals list_mod.StringList)
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
  stdlib.args.ArgsOptionSpecNil)

;: Prepend `spec` to `rest`.
(define (args-option-spec-cons
  [spec : ArgsOptionSpec]
  [rest : ArgsOptionSpecList]) : ArgsOptionSpecList
  (ArgsOptionSpecCons spec (box rest)))

;: Construct a boolean flag spec.
(define (args-flag-option [name : String] [long : String] [short : String]) : ArgsOptionSpec
  (ArgsOptionSpec name long short stdlib.args.ArgsFlag))

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
    (not (string_mod.string-eq (stdlib.args.args-option-spec-long spec) ""))
    (string_mod.string-eq (stdlib.args.args-option-spec-long spec) name)))

;: Return true when `spec` has the short spelling `name`.
(define (args-option-spec-matches-short?
  [spec : ArgsOptionSpec]
  [name : String]) : bool
  (and
    (not (string_mod.string-eq (stdlib.args.args-option-spec-short spec) ""))
    (string_mod.string-eq (stdlib.args.args-option-spec-short spec) name)))

;: Return an empty parsed option list.
(define (args-option-list-empty) : ArgsOptionList
  stdlib.args.ArgsOptionNil)

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
      (stdlib.args.args-option-list-reverse-onto
        (box-get rest)
        (ArgsOptionCons head (box acc)))]))

;: Return options in reverse order.
(define (args-option-list-reverse [items : ArgsOptionList]) : ArgsOptionList
  (stdlib.args.args-option-list-reverse-onto items stdlib.args.ArgsOptionNil))

;: Count parsed option occurrences with the canonical `name`.
(define (args-option-list-count [items : ArgsOptionList] [name : String]) : i64
  (match items
    [(ArgsOptionNil) 0]
    [(ArgsOptionCons head rest)
      (+
        (if (string_mod.string-eq (stdlib.args.args-option-name head) name)
          1
          0)
        (stdlib.args.args-option-list-count (box-get rest) name))]))

;: Return true when `items` contains at least one option with `name`.
(define (args-option-list-present? [items : ArgsOptionList] [name : String]) : bool
  (> (stdlib.args.args-option-list-count items name) 0))

;: Return the last value carried by option `name`, or `fallback` when absent or
;: when only boolean flag occurrences are present.
(define (args-option-list-value-or
  [items : ArgsOptionList]
  [name : String]
  [fallback : String]) : String
  (match items
    [(ArgsOptionNil) fallback]
    [(ArgsOptionCons head rest)
      (stdlib.args.args-option-list-value-or
        (box-get rest)
        name
        (if (and
          (string_mod.string-eq (stdlib.args.args-option-name head) name)
          (stdlib.args.args-option-has-value? head))
          (stdlib.args.args-option-value head)
          fallback))]))

;: Return the parsed option occurrence list.
(define (args-parsed-options [parsed : ArgsParsed]) : ArgsOptionList
  (struct-get parsed options))

;: Return the positional arguments in input order.
(define (args-parsed-positionals [parsed : ArgsParsed]) : list_mod.StringList
  (struct-get parsed positionals))

;: Count option occurrences in a parsed result.
(define (args-option-count [parsed : ArgsParsed] [name : String]) : i64
  (stdlib.args.args-option-list-count
    (stdlib.args.args-parsed-options parsed)
    name))

;: Return true when a parsed result contains option `name`.
(define (args-option-present? [parsed : ArgsParsed] [name : String]) : bool
  (stdlib.args.args-option-list-present?
    (stdlib.args.args-parsed-options parsed)
    name))

;: Return the last parsed value for option `name`, or `fallback`.
(define (args-option-value-or
  [parsed : ArgsParsed]
  [name : String]
  [fallback : String]) : String
  (stdlib.args.args-option-list-value-or
    (stdlib.args.args-parsed-options parsed)
    name
    fallback))

;: Render a parse error as a diagnostic message.
(define (args-error-message [error : ArgsError]) : String
  (match error
    [(ArgsUnknownOption option)
      (string_mod.string-append "args: unknown option " option)]
    [(ArgsMissingValue option)
      (string_mod.string-append "args: missing value for " option)]))

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
  (string_mod.string-eq token "--"))

;: Return true when `token` looks like an option token rather than a positional.
(define (args-option-looking-token? [token : String]) : bool
  (and
    (> (string-length token) 1)
    (string_mod.char-eq (string-ref token 0) #-')))

;: Return true when `token` has the supported long spelling `--name`.
(define (args-long-token? [token : String]) : bool
  (and
    (> (string-length token) 2)
    (string_mod.char-eq (string-ref token 0) #-')
    (string_mod.char-eq (string-ref token 1) #-')))

;: Return true when `token` has the supported short spelling `-x`.
(define (args-short-token? [token : String]) : bool
  (and
    (= (string-length token) 2)
    (string_mod.char-eq (string-ref token 0) #-')))

;: Return the long name portion of a supported long token.
(define (args-token-long-name [token : String]) : String
  (string_mod.substring token 2 (- (string-length token) 2)))

;: Return the short name portion of a supported short token.
(define (args-token-short-name [token : String]) : String
  (string_mod.substring token 1 1))

;: Find a spec by long spelling.
(define (args-find-spec-long [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (match specs
    [(ArgsOptionSpecNil) stdlib.args.ArgsNoOptionSpec]
    [(ArgsOptionSpecCons spec rest)
      (if (stdlib.args.args-option-spec-matches-long? spec name)
        (ArgsSomeOptionSpec spec)
        (stdlib.args.args-find-spec-long (box-get rest) name))]))

;: Find a spec by short spelling.
(define (args-find-spec-short [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (match specs
    [(ArgsOptionSpecNil) stdlib.args.ArgsNoOptionSpec]
    [(ArgsOptionSpecCons spec rest)
      (if (stdlib.args.args-option-spec-matches-short? spec name)
        (ArgsSomeOptionSpec spec)
        (stdlib.args.args-find-spec-short (box-get rest) name))]))

;: Find a matching spec for a supported option token.
(define (args-find-spec-token [specs : ArgsOptionSpecList] [token : String]) : ArgsMaybeOptionSpec
  (if (stdlib.args.args-long-token? token)
    (stdlib.args.args-find-spec-long
      specs
      (stdlib.args.args-token-long-name token))
    (if (stdlib.args.args-short-token? token)
      (stdlib.args.args-find-spec-short
        specs
        (stdlib.args.args-token-short-name token))
      stdlib.args.ArgsNoOptionSpec)))

;: Return a fresh empty parse state.
(define (args-parse-state-empty) : ArgsParseState
  (ArgsParseState stdlib.args.ArgsOptionNil (list_mod.StringNil) false))

;: Add a positional token to a parse state.
(define (args-parse-state-add-positional
  [state : ArgsParseState]
  [value : String]) : ArgsParseState
  (ArgsParseState
    (struct-get state options)
    (list_mod.StringCons value (box (struct-get state positionals)))
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
    (stdlib.args.args-option-list-reverse (struct-get state options))
    (list_mod.string-list-reverse (struct-get state positionals))))

;: Advance past one positional token.
(define (args-advance-positional
  [state : ArgsParseState]
  [current : String]
  [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance
      (stdlib.args.args-parse-state-add-positional state current)
      (+ index 1))))

;: Advance past `--`.
(define (args-advance-end-of-options [state : ArgsParseState] [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance
      (stdlib.args.args-parse-state-stop-options state)
      (+ index 1))))

;: Advance past a known option token, consuming a value when the spec requires
;: one.
(define (args-advance-known-option
  [state : ArgsParseState]
  [spec : ArgsOptionSpec]
  [current : String]
  [next-value : String]
  [has-next : bool]
  [index : i64]) : ResultArgsParseAdvance
  (if (stdlib.args.args-option-arity-value?
    (stdlib.args.args-option-spec-arity spec))
    (if has-next
      (OkArgsParseAdvance
        (ArgsParseAdvance
          (stdlib.args.args-parse-state-add-option
            state
            (stdlib.args.args-option-spec-name spec)
            next-value
            true)
          (+ index 2)))
      (ErrArgsParseAdvance (ArgsMissingValue current)))
    (OkArgsParseAdvance
      (ArgsParseAdvance
        (stdlib.args.args-parse-state-add-option
          state
          (stdlib.args.args-option-spec-name spec)
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
    (stdlib.args.args-advance-positional state current index)
    (if (stdlib.args.args-end-of-options-token? current)
      (stdlib.args.args-advance-end-of-options state index)
      (if (stdlib.args.args-option-looking-token? current)
        (match (stdlib.args.args-find-spec-token specs current)
          [(ArgsNoOptionSpec) (ErrArgsParseAdvance (ArgsUnknownOption current))]
          [(ArgsSomeOptionSpec spec)
            (stdlib.args.args-advance-known-option
              state
              spec
              current
              next-value
              has-next
              index)])
        (stdlib.args.args-advance-positional state current index)))))

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
    (OkArgsParsed (stdlib.args.args-parse-state-finish state))
    (let
      [current : String (array-ref argv index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (array-ref argv (+ index 1))
          "")]
      (match (stdlib.args.args-parse-step
        specs
        state
        current
        next-value
        has-next
        index)
        [(ErrArgsParseAdvance error) (ErrArgsParsed error)]
        [(OkArgsParseAdvance advance)
          (stdlib.args.args-parse-array-loop
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
    [first : i64 (stdlib.args.args-clamp-start start)]
    [last : i64 (stdlib.args.args-clamp-end end limit)]
    (stdlib.args.args-parse-array-loop
      specs
      argv
      first
      last
      (stdlib.args.args-parse-state-empty))))

;: Parse the full argv array.
(define (args-parse-array [specs : ArgsOptionSpecList] [argv : (Array String)]) : ResultArgsParsed
  (stdlib.args.args-parse-array-range specs argv 0 (array-length argv)))

;: Parse process argv range `[index, end)` with `state`.
(define (args-parse-argv-loop
  [specs : ArgsOptionSpecList]
  [index : i64]
  [end : i64]
  [state : ArgsParseState]) : ResultArgsParsed
  (if (>= index end)
    (OkArgsParsed (stdlib.args.args-parse-state-finish state))
    (let
      [current : String (io_mod.arg index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (io_mod.arg (+ index 1))
          "")]
      (match (stdlib.args.args-parse-step
        specs
        state
        current
        next-value
        has-next
        index)
        [(ErrArgsParseAdvance error) (ErrArgsParsed error)]
        [(OkArgsParseAdvance advance)
          (stdlib.args.args-parse-argv-loop
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
    [limit : i64 (io_mod.arg-count)]
    [first : i64 (stdlib.args.args-clamp-start start)]
    [last : i64 (stdlib.args.args-clamp-end end limit)]
    (stdlib.args.args-parse-argv-loop
      specs
      first
      last
      (stdlib.args.args-parse-state-empty))))

;: Parse process argv from `start` through `(arg-count)`.
(define (args-parse-argv [specs : ArgsOptionSpecList] [start : i64]) : ResultArgsParsed
  (stdlib.args.args-parse-argv-range specs start (io_mod.arg-count)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value args-option-spec-empty)
  (value args-option-spec-cons)
  (value args-flag-option)
  (value args-value-option)
  (value args-option-spec-name)
  (value args-option-spec-long)
  (value args-option-spec-short)
  (value args-option-spec-arity)
  (value args-option-arity-value?)
  (value args-option-spec-matches-long?)
  (value args-option-spec-matches-short?)
  (value args-option-list-empty)
  (value args-option-list-cons)
  (value args-option-name)
  (value args-option-value)
  (value args-option-has-value?)
  (value args-option-list-reverse-onto)
  (value args-option-list-reverse)
  (value args-option-list-count)
  (value args-option-list-present?)
  (value args-option-list-value-or)
  (value args-parsed-options)
  (value args-parsed-positionals)
  (value args-option-count)
  (value args-option-present?)
  (value args-option-value-or)
  (value args-error-message)
  (value args-error-unknown-option?)
  (value args-error-missing-value?)
  (value args-error-option)
  (value args-end-of-options-token?)
  (value args-option-looking-token?)
  (value args-long-token?)
  (value args-short-token?)
  (value args-token-long-name)
  (value args-token-short-name)
  (value args-find-spec-long)
  (value args-find-spec-short)
  (value args-find-spec-token)
  (value args-parse-state-empty)
  (value args-parse-state-add-positional)
  (value args-parse-state-add-option)
  (value args-parse-state-stop-options)
  (value args-parse-state-finish)
  (value args-advance-positional)
  (value args-advance-end-of-options)
  (value args-advance-known-option)
  (value args-parse-step)
  (value args-clamp-start)
  (value args-clamp-end)
  (value args-parse-array-loop)
  (value args-parse-array-range)
  (value args-parse-array)
  (value args-parse-argv-loop)
  (value args-parse-argv-range)
  (value args-parse-argv)
  (type ArgsOptionArity)
  (type ArgsOptionSpec)
  (type ArgsOptionSpecList)
  (type ArgsOption)
  (type ArgsOptionList)
  (type ArgsParsed)
  (type ArgsError)
  (type ResultArgsParsed)
  (type ArgsMaybeOptionSpec)
  (type ArgsParseState)
  (type ArgsParseAdvance)
  (type ResultArgsParseAdvance)
  (constructor ArgsOptionSpec)
  (constructor ArgsOption)
  (constructor ArgsParsed)
  (constructor ArgsParseState)
  (constructor ArgsParseAdvance)
  (field ArgsOptionSpec name)
  (field ArgsOptionSpec long)
  (field ArgsOptionSpec short)
  (field ArgsOptionSpec arity)
  (field ArgsOption name)
  (field ArgsOption value)
  (field ArgsOption has-value)
  (field ArgsParsed options)
  (field ArgsParsed positionals)
  (field ArgsParseState options)
  (field ArgsParseState positionals)
  (field ArgsParseState stop-options)
  (field ArgsParseAdvance state)
  (field ArgsParseAdvance next-index)
  (variant ArgsFlag)
  (variant ArgsValue)
  (variant ArgsOptionSpecNil)
  (variant ArgsOptionSpecCons)
  (variant ArgsOptionNil)
  (variant ArgsOptionCons)
  (variant ArgsUnknownOption)
  (variant ArgsMissingValue)
  (variant OkArgsParsed)
  (variant ErrArgsParsed)
  (variant ArgsNoOptionSpec)
  (variant ArgsSomeOptionSpec)
  (variant OkArgsParseAdvance)
  (variant ErrArgsParseAdvance))