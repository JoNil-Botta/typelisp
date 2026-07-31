;# stdlib/args.tl - Reusable argv option parser.
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
;# is involved; `parse-argv*` only reads the raw argv accessors from
;# `stdlib/io.tl`.
;#
;# Usage: `(import stdlib.args)`
;#
;# ```typelisp
;# (import stdlib.args)
;# (define specs : args.ArgsOptionSpecList
;#   (args.option-spec-cons
;#     (args.value-option "output" "output" "o")
;#     (args.option-spec-cons
;#       (args.flag-option "verbose" "verbose" "v")
;#       (args.option-spec-empty))))
;# (define (main) : i64
;#   (match (args.parse-argv specs 1)
;#     [(args.OkArgsParsed parsed)
;#       (if (args.option-present? parsed "verbose") 1 0)]
;#     [(args.ErrArgsParsed _) 2]))
;# ```
(import stdlib.array)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

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

;: Immutable sequence of option specs in a contiguous backing array.
(defstruct ArgsOptionSpecList
  (slots (Array ArgsOptionSpec))
  (len i64))

;: One parsed option occurrence in input order. Boolean flags set `has-value`
;: false and store the empty string as `value`.
(defstruct ArgsOption
  (name String)
  (value String)
  (has-value bool))

;: Immutable sequence of parsed option occurrences in a contiguous backing
;: array. `len` is the live prefix; the array may hold builder slack.
(defstruct ArgsOptionList
  (slots (Array ArgsOption))
  (len i64))

;: Parsed argv result: ordered option occurrences and ordered positionals.
(defstruct ArgsParsed
  (options ArgsOptionList)
  (positionals svec.Vec))

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

;: Internal parse accumulator. Options and positionals are both appended in
;: input order, so the final result needs no reordering.
(defstruct ArgsParseState
  (options ArgsOptionList)
  (positionals svec.Vec)
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
(define (option-spec-empty) : ArgsOptionSpecList
  (ArgsOptionSpecList (array.make-array ArgsOptionSpec 0) 0))

;: Prepend `spec` to `rest`, copying `rest` into a right-sized array.
(define (option-spec-cons [spec : ArgsOptionSpec] [rest : ArgsOptionSpecList]) : ArgsOptionSpecList
  (let
    [len : i64 (struct-get rest len)]
    [slots : (Array ArgsOptionSpec) (array.make-array ArgsOptionSpec (+ len 1))]
    [index : i64 0]
    (begin
      (array-set! slots 0 spec)
      (while (< index len)
        (begin
          (array-set!
            slots
            (+ index 1)
            (array-ref (struct-get rest slots) index))
          (set! index (+ index 1))))
      (ArgsOptionSpecList slots (+ len 1)))))

;: Construct a boolean flag spec.
(define (flag-option [name : String] [long : String] [short : String]) : ArgsOptionSpec
  (ArgsOptionSpec name long short (ArgsFlag)))

;: Construct a value-consuming flag spec.
(define (value-option [name : String] [long : String] [short : String]) : ArgsOptionSpec
  (ArgsOptionSpec name long short (ArgsValue)))

;: Return the canonical name for a spec.
(define (option-spec-name [spec : ArgsOptionSpec]) : String
  (struct-get spec name))

;: Return the long spelling for a spec, without leading dashes.
(define (option-spec-long [spec : ArgsOptionSpec]) : String
  (struct-get spec long))

;: Return the short spelling for a spec, without the leading dash.
(define (option-spec-short [spec : ArgsOptionSpec]) : String
  (struct-get spec short))

;: Return the arity for a spec.
(define (option-spec-arity [spec : ArgsOptionSpec]) : ArgsOptionArity
  (struct-get spec arity))

;: Return true when an arity consumes a following value.
(define (option-arity-value? [arity : ArgsOptionArity]) : bool
  (match arity
    [(ArgsFlag) false]
    [(ArgsValue) true]))

;: Return true when `spec` has the long spelling `name`.
(define (option-spec-matches-long? [spec : ArgsOptionSpec] [name : String]) : bool
  (if (not (string.eq (option-spec-long spec) ""))
    (string.eq (option-spec-long spec) name)
    false))

;: Return true when `spec` has the short spelling `name`.
(define (option-spec-matches-short? [spec : ArgsOptionSpec] [name : String]) : bool
  (if (not (string.eq (option-spec-short spec) ""))
    (string.eq (option-spec-short spec) name)
    false))

;: Copy `count` occurrences from `src` into `dst` starting at `offset`.
(define (option-list-copy!
  [dst : (&mut dst (Array ArgsOption))]
  [src : (& src (Array ArgsOption))]
  [offset : i64]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst (+ index offset) (array-ref src index))
        (set! index (+ index 1))))))

;: Return an empty parsed option list.
(define (option-list-empty) : ArgsOptionList
  (ArgsOptionList (array.make-array ArgsOption 0) 0))

;: Prepend one parsed option occurrence, copying `rest` into a right-sized
;: array.
(define (option-list-cons [option : ArgsOption] [rest : ArgsOptionList]) : ArgsOptionList
  (let
    [len : i64 (struct-get rest len)]
    [slots : (Array ArgsOption) (array.make-array ArgsOption (+ len 1))]
    (begin
      (array-set! slots 0 option)
      (option-list-copy! (&mut slots) (& (struct-get rest slots)) 1 len)
      (ArgsOptionList slots (+ len 1)))))

;: Append one parsed option occurrence, doubling the backing array when the
;: live prefix has filled it.
(define (option-list-push [items : ArgsOptionList] [option : ArgsOption]) : ArgsOptionList
  (let
    [len : i64 (struct-get items len)]
    [slots : (Array ArgsOption) (struct-get items slots)]
    [capacity : i64 (array-length slots)]
    (begin
      (if (< len capacity)
        unit
        (let
          [bigger : (Array ArgsOption)
            (array.make-array
              ArgsOption
              (if (< capacity 1)
                4
                (* capacity 2)))]
          (begin
            (option-list-copy! (&mut bigger) (& slots) 0 len)
            (set! slots bigger))))
      (array-set! slots len option)
      (ArgsOptionList slots (+ len 1)))))

;: Return a parsed option occurrence's canonical name.
(define (option-name [option : ArgsOption]) : String
  (struct-get option name))

;: Return a parsed option occurrence's value, or the empty string for flags.
(define (option-value [option : ArgsOption]) : String
  (struct-get option value))

;: Return true when a parsed option occurrence carries a value.
(define (option-has-value? [option : ArgsOption]) : bool
  (struct-get option has-value))

;: Count parsed option occurrences with the canonical `name`.
(define (option-list-count [items : ArgsOptionList] [name : String]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (struct-get items len))
        (begin
          (if (string.eq
            (option-name (array-ref (struct-get items slots) index))
            name)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      count)))

;: Return true when `items` contains at least one option with `name`.
(define (option-list-present? [items : ArgsOptionList] [name : String]) : bool
  (> (option-list-count items name) 0))

;: Return the last value carried by option `name`, or `fallback` when absent or
;: when only boolean flag occurrences are present.
(define (option-list-value-or
  [items : ArgsOptionList]
  [name : String]
  [fallback : String]) : String
  (let
    [index : i64 0]
    [result : String fallback]
    (begin
      (while (< index (struct-get items len))
        (let
          [head : ArgsOption (array-ref (struct-get items slots) index)]
          (begin
            (if (if (string.eq (option-name head) name)
              (option-has-value? head)
              false)
              (set! result (option-value head))
              unit)
            (set! index (+ index 1)))))
      result)))

;: Return the parsed option occurrence list.
(define (parsed-options [parsed : ArgsParsed]) : ArgsOptionList
  (struct-get parsed options))

;: Borrow the positional arguments in input order.
(define (parsed-positionals [parsed : (& parsed ArgsParsed)]) : (&
    parsed
    svec.Vec)
  (& (struct-get parsed positionals)))

;: Count option occurrences in a parsed result.
(define (option-count [parsed : ArgsParsed] [name : String]) : i64
  (option-list-count (parsed-options parsed) name))

;: Return true when a parsed result contains option `name`.
(define (option-present? [parsed : ArgsParsed] [name : String]) : bool
  (option-list-present? (parsed-options parsed) name))

;: Return the last parsed value for option `name`, or `fallback`.
(define (option-value-or
  [parsed : ArgsParsed]
  [name : String]
  [fallback : String]) : String
  (option-list-value-or (parsed-options parsed) name fallback))

;: Render a parse error as a diagnostic message.
(define (error-message [error : ArgsError]) : String
  (match error
    [(ArgsUnknownOption option)
      (str_cat.str-cat "args: unknown option " option)]
    [(ArgsMissingValue option)
      (str_cat.str-cat "args: missing value for " option)]))

;: Return true for unknown-option errors.
(define (error-unknown-option? [error : ArgsError]) : bool
  (match error
    [(ArgsUnknownOption _) true]
    [(ArgsMissingValue _) false]))

;: Return true for missing-value errors.
(define (error-missing-value? [error : ArgsError]) : bool
  (match error
    [(ArgsUnknownOption _) false]
    [(ArgsMissingValue _) true]))

;: Return the original option token carried by an error.
(define (error-option [error : ArgsError]) : String
  (match error
    [(ArgsUnknownOption option) option]
    [(ArgsMissingValue option) option]))

;: Return true when `token` is exactly `--`.
(define (end-of-options-token? [token : String]) : bool
  (string.eq token "--"))

;: Return true when `token` looks like an option token rather than a positional.
(define (option-looking-token? [token : String]) : bool
  (and (> (string-length token) 1) (string.char-eq (string-ref token 0) '-')))

;: Return true when `token` has the supported long spelling `--name`.
(define (long-token? [token : String]) : bool
  (and
    (> (string-length token) 2)
    (string.char-eq (string-ref token 0) '-')
    (string.char-eq (string-ref token 1) '-')))

;: Return true when `token` has the supported short spelling `-x`.
(define (short-token? [token : String]) : bool
  (and (= (string-length token) 2) (string.char-eq (string-ref token 0) '-')))

;: Return the long name portion of a supported long token.
(define (token-long-name [token : String]) : String
  (string.substring token 2 (- (string-length token) 2)))

;: Return the short name portion of a supported short token.
(define (token-short-name [token : String]) : String
  (string.substring token 1 1))

;: Find the first spec from `index` matching `name`, comparing long spellings
;: when `long?` is true and short spellings otherwise.
(define (find-spec-from
  [specs : ArgsOptionSpecList]
  [name : String]
  [long? : bool]
  [index : i64]) : ArgsMaybeOptionSpec
  (if (>= index (struct-get specs len))
    (ArgsNoOptionSpec)
    (let
      [spec : ArgsOptionSpec (array-ref (struct-get specs slots) index)]
      (if (if long?
        (option-spec-matches-long? spec name)
        (option-spec-matches-short? spec name))
        (ArgsSomeOptionSpec spec)
        (find-spec-from specs name long? (+ index 1))))))

;: Find a spec by long spelling.
(define (find-spec-long [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (find-spec-from specs name true 0))

;: Find a spec by short spelling.
(define (find-spec-short [specs : ArgsOptionSpecList] [name : String]) : ArgsMaybeOptionSpec
  (find-spec-from specs name false 0))

;: Find a matching spec for a supported option token.
(define (find-spec-token [specs : ArgsOptionSpecList] [token : String]) : ArgsMaybeOptionSpec
  (if (long-token? token)
    (find-spec-long specs (token-long-name token))
    (if (short-token? token)
      (find-spec-short specs (token-short-name token))
      (ArgsNoOptionSpec))))

;: Return a fresh empty parse state.
(define (parse-state-empty) : ArgsParseState
  (ArgsParseState (option-list-empty) (svec.new) false))

;: Add a positional token to a parse state.
(define (parse-state-add-positional
  [state : ArgsParseState (:consume)]
  [value : String]) : ArgsParseState
  (let
    [positionals : svec.Vec (struct-get state positionals)]
    (begin
      (svec.push (&mut positionals) value)
      (ArgsParseState
        (struct-get state options)
        positionals
        (struct-get state stop-options)))))

;: Add a parsed option occurrence to a parse state.
(define (parse-state-add-option
  [state : ArgsParseState]
  [name : String]
  [value : String]
  [has-value : bool]) : ArgsParseState
  (ArgsParseState
    (option-list-push
      (struct-get state options)
      (ArgsOption name value has-value))
    (struct-get state positionals)
    (struct-get state stop-options)))

;: Mark the parse state as past `--`.
(define (parse-state-stop-options [state : ArgsParseState]) : ArgsParseState
  (ArgsParseState
    (struct-get state options)
    (struct-get state positionals)
    true))

;: Convert the parse state into the public ordered result.
(define (parse-state-finish [state : ArgsParseState]) : ArgsParsed
  (ArgsParsed (struct-get state options) (struct-get state positionals)))

;: Finish parser field accumulators into the public ordered result.
(define (parse-finish-fields
  [options : ArgsOptionList]
  [positionals : svec.Vec]) : ArgsParsed
  (ArgsParsed options positionals))

;: Advance past one positional token.
(define (advance-positional
  [state : ArgsParseState]
  [current : String]
  [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance (parse-state-add-positional state current) (+ index 1))))

;: Advance past `--`.
(define (advance-end-of-options [state : ArgsParseState] [index : i64]) : ResultArgsParseAdvance
  (OkArgsParseAdvance
    (ArgsParseAdvance (parse-state-stop-options state) (+ index 1))))

;: Advance past a known option token, consuming a value when the spec requires
;: one.
(define (advance-known-option
  [state : ArgsParseState]
  [spec : ArgsOptionSpec]
  [current : String]
  [next-value : String]
  [has-next : bool]
  [index : i64]) : ResultArgsParseAdvance
  (if (option-arity-value? (option-spec-arity spec))
    (if has-next
      (OkArgsParseAdvance
        (ArgsParseAdvance
          (parse-state-add-option state (option-spec-name spec) next-value true)
          (+ index 2)))
      (ErrArgsParseAdvance (ArgsMissingValue current)))
    (OkArgsParseAdvance
      (ArgsParseAdvance
        (parse-state-add-option state (option-spec-name spec) "" false)
        (+ index 1)))))

;: Parse one token from a sequence.
(define (parse-step
  [specs : ArgsOptionSpecList]
  [state : ArgsParseState]
  [current : String]
  [next-value : String]
  [has-next : bool]
  [index : i64]) : ResultArgsParseAdvance
  (cond
    [(struct-get state stop-options)
      (stdlib.args.advance-positional state current index)]
    [(stdlib.args.end-of-options-token? current)
      (stdlib.args.advance-end-of-options state index)]
    [(stdlib.args.option-looking-token? current)
      (match (stdlib.args.find-spec-token specs current)
        [(ArgsNoOptionSpec) (ErrArgsParseAdvance (ArgsUnknownOption current))]
        [(ArgsSomeOptionSpec spec)
          (stdlib.args.advance-known-option
            state
            spec
            current
            next-value
            has-next
            index)])]
    [else (stdlib.args.advance-positional state current index)]))

;: Clamp a sequence start index to zero.
(define (clamp-start [start : i64]) : i64
  (if (< start 0)
    0
    start))

;: Clamp an exclusive end index into `[0, limit]`.
(define (clamp-end [end : i64] [limit : i64]) : i64
  (let
    [non-negative : i64
      (if (< end 0)
        0
        end)]
    (if (> non-negative limit)
      limit
      non-negative)))

;: Parse the array range `[index, end)` with `state`.
(define (parse-array-loop-fields
  [specs : ArgsOptionSpecList]
  [argv : (Array String)]
  [index : i64]
  [end : i64]
  [options : ArgsOptionList]
  [positionals : svec.Vec (:consume)]
  [stop-options : bool]) : ResultArgsParsed
  (if (>= index end)
    (OkArgsParsed (parse-finish-fields options positionals))
    (let
      [current : String (array-ref argv index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (array-ref argv (+ index 1))
          "")]
      (cond
        [stop-options
          (begin
            (svec.push (&mut positionals) current)
            (parse-array-loop-fields
              specs
              argv
              (+ index 1)
              end
              options
              positionals
              stop-options))]
        [(stdlib.args.end-of-options-token? current)
          (parse-array-loop-fields
            specs
            argv
            (+ index 1)
            end
            options
            positionals
            true)]
        [(stdlib.args.option-looking-token? current)
          (match (stdlib.args.find-spec-token specs current)
            [(ArgsNoOptionSpec) (ErrArgsParsed (ArgsUnknownOption current))]
            [(ArgsSomeOptionSpec spec)
              (if (stdlib.args.option-arity-value?
                (stdlib.args.option-spec-arity spec))
                (if has-next
                  (parse-array-loop-fields
                    specs
                    argv
                    (+ index 2)
                    end
                    (stdlib.args.option-list-push
                      options
                      (ArgsOption
                        (stdlib.args.option-spec-name spec)
                        next-value
                        true))
                    positionals
                    stop-options)
                  (ErrArgsParsed (ArgsMissingValue current)))
                (parse-array-loop-fields
                  specs
                  argv
                  (+ index 1)
                  end
                  (stdlib.args.option-list-push
                    options
                    (ArgsOption (stdlib.args.option-spec-name spec) "" false))
                  positionals
                  stop-options))])]
        [else
          (begin
            (svec.push (&mut positionals) current)
            (parse-array-loop-fields
              specs
              argv
              (+ index 1)
              end
              options
              positionals
              stop-options))]))))

;: Bridge an `ArgsParseState` into the field-based array parser loop.
(define (parse-array-loop
  [specs : ArgsOptionSpecList]
  [argv : (Array String)]
  [index : i64]
  [end : i64]
  [state : ArgsParseState]) : ResultArgsParsed
  (parse-array-loop-fields
    specs
    argv
    index
    end
    (struct-get state options)
    (struct-get state positionals)
    (struct-get state stop-options)))

;: Parse the array range `[start, end)`. Negative bounds clamp to zero and end
;: clamps to the array length.
(define (parse-array-range
  [specs : ArgsOptionSpecList]
  [argv : (Array String)]
  [start : i64]
  [end : i64]) : ResultArgsParsed
  (let
    [limit : i64 (array-length argv)]
    [i : i64 (stdlib.args.clamp-start start)]
    [last : i64 (stdlib.args.clamp-end end limit)]
    [options : ArgsOptionList (stdlib.args.option-list-empty)]
    [positionals : svec.Vec (svec.new)]
    [stop-options : bool false]
    [failed : bool false]
    [error : ArgsError (stdlib.args.ArgsUnknownOption "")]
    (begin
      (while (and (< i last) (not failed))
        (let
          [current : String (array-ref argv i)]
          [has-next : bool (< (+ i 1) last)]
          [next-value : String
            (if has-next
              (array-ref argv (+ i 1))
              "")]
          (cond
            [stop-options
              (begin
                (svec.push (&mut positionals) current)
                (set! i (+ i 1)))]
            [(stdlib.args.end-of-options-token? current)
              (begin
                (set! stop-options true)
                (set! i (+ i 1)))]
            [(stdlib.args.option-looking-token? current)
              (match (stdlib.args.find-spec-token specs current)
                [(stdlib.args.ArgsNoOptionSpec)
                  (begin
                    (set! error (stdlib.args.ArgsUnknownOption current))
                    (set! failed true))]
                [(stdlib.args.ArgsSomeOptionSpec spec)
                  (if (stdlib.args.option-arity-value?
                    (stdlib.args.option-spec-arity spec))
                    (if has-next
                      (begin
                        (set!
                          options
                          (stdlib.args.option-list-push
                            options
                            (stdlib.args.ArgsOption
                              (stdlib.args.option-spec-name spec)
                              next-value
                              true)))
                        (set! i (+ i 2)))
                      (begin
                        (set! error (stdlib.args.ArgsMissingValue current))
                        (set! failed true)))
                    (begin
                      (set!
                        options
                        (stdlib.args.option-list-push
                          options
                          (stdlib.args.ArgsOption
                            (stdlib.args.option-spec-name spec)
                            ""
                            false)))
                      (set! i (+ i 1))))])]
            [else
              (begin
                (svec.push (&mut positionals) current)
                (set! i (+ i 1)))])))
      (if failed
        (stdlib.args.ErrArgsParsed error)
        (stdlib.args.OkArgsParsed (parse-finish-fields options positionals))))))

;: Parse the full argv array.
(define (parse-array [specs : ArgsOptionSpecList] [argv : (Array String)]) : ResultArgsParsed
  (parse-array-range specs argv 0 (array-length argv)))

;: Parse process argv range `[index, end)` with `state`.
(define (parse-argv-loop-fields
  [specs : ArgsOptionSpecList]
  [index : i64]
  [end : i64]
  [options : ArgsOptionList]
  [positionals : svec.Vec (:consume)]
  [stop-options : bool]) : ResultArgsParsed
  (if (>= index end)
    (OkArgsParsed (parse-finish-fields options positionals))
    (let
      [current : String (io.arg index)]
      [has-next : bool (< (+ index 1) end)]
      [next-value : String
        (if has-next
          (io.arg (+ index 1))
          "")]
      (cond
        [stop-options
          (begin
            (svec.push (&mut positionals) current)
            (parse-argv-loop-fields
              specs
              (+ index 1)
              end
              options
              positionals
              stop-options))]
        [(stdlib.args.end-of-options-token? current)
          (parse-argv-loop-fields
            specs
            (+ index 1)
            end
            options
            positionals
            true)]
        [(stdlib.args.option-looking-token? current)
          (match (stdlib.args.find-spec-token specs current)
            [(ArgsNoOptionSpec) (ErrArgsParsed (ArgsUnknownOption current))]
            [(ArgsSomeOptionSpec spec)
              (if (stdlib.args.option-arity-value?
                (stdlib.args.option-spec-arity spec))
                (if has-next
                  (parse-argv-loop-fields
                    specs
                    (+ index 2)
                    end
                    (stdlib.args.option-list-push
                      options
                      (ArgsOption
                        (stdlib.args.option-spec-name spec)
                        next-value
                        true))
                    positionals
                    stop-options)
                  (ErrArgsParsed (ArgsMissingValue current)))
                (parse-argv-loop-fields
                  specs
                  (+ index 1)
                  end
                  (stdlib.args.option-list-push
                    options
                    (ArgsOption (stdlib.args.option-spec-name spec) "" false))
                  positionals
                  stop-options))])]
        [else
          (begin
            (svec.push (&mut positionals) current)
            (parse-argv-loop-fields
              specs
              (+ index 1)
              end
              options
              positionals
              stop-options))]))))

;: Bridge an `ArgsParseState` into the field-based process argv parser loop.
(define (parse-argv-loop
  [specs : ArgsOptionSpecList]
  [index : i64]
  [end : i64]
  [state : ArgsParseState]) : ResultArgsParsed
  (parse-argv-loop-fields
    specs
    index
    end
    (struct-get state options)
    (struct-get state positionals)
    (struct-get state stop-options)))

;: Parse the process argv range `[start, end)`. Negative bounds clamp to zero
;: and end clamps to `(arg-count)`.
(define (parse-argv-range
  [specs : ArgsOptionSpecList]
  [start : i64]
  [end : i64]) : ResultArgsParsed
  (let
    [limit : i64 (io.arg-count)]
    [i : i64 (stdlib.args.clamp-start start)]
    [last : i64 (stdlib.args.clamp-end end limit)]
    [options : ArgsOptionList (stdlib.args.option-list-empty)]
    [positionals : svec.Vec (svec.new)]
    [stop-options : bool false]
    [failed : bool false]
    [error : ArgsError (stdlib.args.ArgsUnknownOption "")]
    (begin
      (while (and (< i last) (not failed))
        (let
          [current : String (io.arg i)]
          [has-next : bool (< (+ i 1) last)]
          [next-value : String
            (if has-next
              (io.arg (+ i 1))
              "")]
          (cond
            [stop-options
              (begin
                (svec.push (&mut positionals) current)
                (set! i (+ i 1)))]
            [(stdlib.args.end-of-options-token? current)
              (begin
                (set! stop-options true)
                (set! i (+ i 1)))]
            [(stdlib.args.option-looking-token? current)
              (match (stdlib.args.find-spec-token specs current)
                [(stdlib.args.ArgsNoOptionSpec)
                  (begin
                    (set! error (stdlib.args.ArgsUnknownOption current))
                    (set! failed true))]
                [(stdlib.args.ArgsSomeOptionSpec spec)
                  (if (stdlib.args.option-arity-value?
                    (stdlib.args.option-spec-arity spec))
                    (if has-next
                      (begin
                        (set!
                          options
                          (stdlib.args.option-list-push
                            options
                            (stdlib.args.ArgsOption
                              (stdlib.args.option-spec-name spec)
                              next-value
                              true)))
                        (set! i (+ i 2)))
                      (begin
                        (set! error (stdlib.args.ArgsMissingValue current))
                        (set! failed true)))
                    (begin
                      (set!
                        options
                        (stdlib.args.option-list-push
                          options
                          (stdlib.args.ArgsOption
                            (stdlib.args.option-spec-name spec)
                            ""
                            false)))
                      (set! i (+ i 1))))])]
            [else
              (begin
                (svec.push (&mut positionals) current)
                (set! i (+ i 1)))])))
      (if failed
        (stdlib.args.ErrArgsParsed error)
        (stdlib.args.OkArgsParsed (parse-finish-fields options positionals))))))

;: Parse process argv from `start` through `(arg-count)`.
(define (parse-argv [specs : ArgsOptionSpecList] [start : i64]) : ResultArgsParsed
  (parse-argv-range specs start (io.arg-count)))

;: Inline test assertion for boolean predicates.
(define (test-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

;: Inline test assertion for `i64` equality.
(define (test-assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test-assert-true (string.eq actual expected) message))

;: Build the option specs used by argv parser inline tests.
(define (test-specs) : ArgsOptionSpecList
  (option-spec-cons
    (value-option "output" "output" "o")
    (option-spec-cons
      (value-option "include" "include" "I")
      (option-spec-cons
        (flag-option "verbose" "verbose" "v")
        (option-spec-empty)))))

;: Build a zero-length argv array for inline tests.
(define (test-array0) : (Array String)
  (array.make-array String 0))

;: Build a one-item argv array for inline tests.
(define (test-array1 [a : String]) : (Array String)
  (make-array a))

;: Build a three-item argv array for inline tests.
(define (test-array3 [a : String] [b : String] [c : String]) : (Array String)
  (make-array a b c))

;: Build a five-item argv array for inline tests.
(define (test-array5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : (Array String)
  (make-array a b c d e))

;: Build a six-item argv array for inline tests.
(define (test-array6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : (Array String)
  (make-array a b c d e f))

;: Unwrap a successful argv parse result for inline tests.
(define (test-expect-ok [result : ResultArgsParsed] [message : String]) : ArgsParsed
  (match result
    [(OkArgsParsed parsed) parsed]
    [(ErrArgsParsed _) (io.panic message)]))

;: Unwrap a failed argv parse result for inline tests.
(define (test-expect-error [result : ResultArgsParsed] [message : String]) : ArgsError
  (match result
    [(OkArgsParsed _) (io.panic message)]
    [(ErrArgsParsed error) error]))

;: Assert that a string vector is empty.
(define (test-assert-string-vec-empty
  [items : (& items svec.Vec)]
  [message : String]) : unit
  (test-assert-i64-eq (svec.len items) 0 message))

;: Assert that a string vector contains exactly two strings.
(define (test-assert-string-vec2
  [items : (& items svec.Vec)]
  [first : String]
  [second : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len items) 2 (str_cat.str-cat message " count"))
    (test-assert-owned-string-eq
      (svec.get items 0 "")
      first
      (str_cat.str-cat message " first"))
    (test-assert-owned-string-eq
      (svec.get items 1 "")
      second
      (str_cat.str-cat message " second"))))

;: Assert that a string vector contains exactly three strings.
(define (test-assert-string-vec3
  [items : (& items svec.Vec)]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len items) 3 (str_cat.str-cat message " count"))
    (test-assert-owned-string-eq
      (svec.get items 0 "")
      first
      (str_cat.str-cat message " first"))
    (test-assert-owned-string-eq
      (svec.get items 1 "")
      second
      (str_cat.str-cat message " second"))
    (test-assert-owned-string-eq
      (svec.get items 2 "")
      third
      (str_cat.str-cat message " third"))))

;: Exercise an empty argv sequence.
(define (test-empty-argv) : unit
  (let
    [parsed : ArgsParsed
      (test-expect-ok
        (parse-array (test-specs) (test-array0))
        "empty argv should parse")]
    (begin
      (test-assert-string-vec-empty
        (parsed-positionals (& parsed))
        "empty argv has no positionals")
      (test-assert-i64-eq
        (option-count parsed "verbose")
        0
        "empty argv has no flags"))))

;: Exercise positional-only argv parsing.
(define (test-positionals-only) : unit
  (let
    [argv : (Array String) (test-array3 "src.tl" "out.s" "-")]
    [parsed : ArgsParsed
      (test-expect-ok
        (begin
          (test-assert-i64-eq (array-length argv) 3 "test-array3 length")
          (parse-array (test-specs) argv))
        "positional-only argv should parse")]
    (test-assert-string-vec3
      (begin
        (test-assert-i64-eq
          (svec.len (parsed-positionals (& parsed)))
          3
          "positionals parsed count")
        (parsed-positionals (& parsed)))
      "src.tl"
      "out.s"
      "-"
      "positionals preserve input order")))

;: Exercise options interleaved with positionals.
(define (test-flags-around-positionals) : unit
  (let
    [parsed : ArgsParsed
      (test-expect-ok
        (parse-array
          (test-specs)
          (test-array5 "input.tl" "--verbose" "-o" "out.s" "rest"))
        "flags around positionals should parse")]
    (begin
      (test-assert-true
        (option-present? parsed "verbose")
        "long boolean flag present")
      (test-assert-i64-eq
        (option-count parsed "output")
        1
        "short value flag counted")
      (test-assert-owned-string-eq
        (option-value-or parsed "output" "missing")
        "out.s"
        "short value flag consumes next argv")
      (test-assert-string-vec2
        (parsed-positionals (& parsed))
        "input.tl"
        "rest"
        "positionals before and after flags preserved"))))

;: Exercise `--` end-of-options handling.
(define (test-end-of-options) : unit
  (let
    [parsed : ArgsParsed
      (test-expect-ok
        (parse-array (test-specs) (test-array3 "--" "--verbose" "-o"))
        "end-of-options should parse")]
    (begin
      (test-assert-i64-eq
        (option-count parsed "verbose")
        0
        "options after -- are positionals")
      (test-assert-string-vec2
        (parsed-positionals (& parsed))
        "--verbose"
        "-o"
        "-- preserves following tokens as positionals"))))

;: Exercise missing-value diagnostics.
(define (test-missing-value) : unit
  (let
    [error : ArgsError
      (test-expect-error
        (parse-array (test-specs) (test-array1 "--output"))
        "missing value should fail")]
    (begin
      (test-assert-true (error-missing-value? error) "missing value error kind")
      (test-assert-owned-string-eq
        (error-option error)
        "--output"
        "missing value carries token"))))

;: Exercise unknown-option diagnostics.
(define (test-unknown-option) : unit
  (let
    [error : ArgsError
      (test-expect-error
        (parse-array (test-specs) (test-array1 "--missing"))
        "unknown option should fail")]
    (begin
      (test-assert-true
        (error-unknown-option? error)
        "unknown option error kind")
      (test-assert-owned-string-eq
        (error-option error)
        "--missing"
        "unknown option carries token"))))

;: Exercise repeated short and long options.
(define (test-repeated-options) : unit
  (let
    [parsed : ArgsParsed
      (test-expect-ok
        (parse-array
          (test-specs)
          (test-array6 "-I" "inc1" "--include" "inc2" "-v" "-v"))
        "repeated options should parse")]
    (begin
      (test-assert-i64-eq
        (option-count parsed "include")
        2
        "repeated value option count")
      (test-assert-owned-string-eq
        (option-value-or parsed "include" "missing")
        "inc2"
        "last repeated value returned")
      (test-assert-i64-eq
        (option-count parsed "verbose")
        2
        "repeated boolean flag count"))))

;: Exercise intentionally unsupported `--name=value` spelling.
(define (test-equals-spelling-unsupported) : unit
  (let
    [error : ArgsError
      (test-expect-error
        (parse-array (test-specs) (test-array1 "--output=file"))
        "equals spelling should be rejected in v1")]
    (begin
      (test-assert-true
        (error-unknown-option? error)
        "equals spelling is intentionally unknown")
      (test-assert-owned-string-eq
        (error-option error)
        "--output=file"
        "equals spelling carries original token"))))