;; compiler_tlci_native_producer_tests.tl - the producer's `run-ops` batching:
;; which op lines become batch tokens and how the status chain renders a run
;; of them. The host side of the batch format is covered by
;; src/tests/comptime_host_smoke.tl, and the gates that compile every stdlib
;; macro through both routes cover the end-to-end expansions. Refs #8274.
(import stdlib.iterator)
(import compiler_tlci_native_producer as producer)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)
(import tlci_core)

;; The batch tokens of `line`, or "none" when it is not batchable.
(define (batch-tokens [line : String]) : String
  (match (producer.embedded-native-batch-op (& line))
    [(EmbeddedNativeBatchOpSome name tokens) (str_cat.str-cat name tokens)]
    [(EmbeddedNativeBatchOpNone) "none"]))

(define (name-arg [escaped : String]) : String
  (str_cat.str-cat
    "(cast (unsafe (ptr->int (string-data \""
    (str_cat.str-cat escaped "\"))) : i64)")))

(define (op-line [name : String] [args : String]) : String
  (str_cat.str-cat
    "(comptime-host-"
    (str_cat.str-cat
      name
      (str_cat.str-cat " host session " (str_cat.str-cat args ")")))))

(test
  batch-op-constant-immediates
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "3 14 -21474836480"))
    "expr-spanA3A>fD00000"
    "integer immediates become batch integers")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat (name-arg "value") " 5 0")))
    "expr-var#A5valueA5@"
    "a name argument carries its bytes")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "string-value"
        (str_cat.str-cat (name-arg "a\\\"b\\\\c\\n d") " 8 0")))
    "string-value#A8a\"b\\c\n dA8@"
    "escapes are undone and the byte length counts raw bytes")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "type-ref"
        (str_cat.str-cat "1 " (str_cat.str-cat (name-arg "r") " 1"))))
    "type-refA1#A1rA1"
    "a name argument may sit in the middle position"))

(test
  batch-op-rejects-non-constant-shapes
  (test.assert-owned-string-eq
    (batch-tokens (op-line "local-get" "k3 0 0"))
    "none"
    "a generated variable is not a constant")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat (name-arg "value") " 4 0")))
    "none"
    "the length after a name must be its byte length")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat "0 0 " (name-arg "value"))))
    "none"
    "a name in the last position has no length")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "expr-var"
        (str_cat.str-cat
          (name-arg "a")
          (str_cat.str-cat " " (str_cat.str-cat (name-arg "b") " 1")))))
    "none"
    "a name cannot follow a name")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1  2 3"))
    "none"
    "only the canonical spacing parses")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1 2 1234567890123456789"))
    "none"
    "a 19-digit immediate is not batched")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1 2 3 4"))
    "none"
    "an op takes exactly three immediates")
  (test.assert-owned-string-eq
    (batch-tokens "(other-call host session 0 0 0)")
    "none"
    "only host calls are batched"))

;; The number of `(` minus `)` in `text` outside string literals.
(define (open-parens [text : (& text str)]) : i64
  (let
    [depth : i64 0]
    [index : i64 0]
    [in-string : bool false]
    (while (< index (string.string-length text))
      (let
        [c : char (string.string-ref text index)]
        (cond
          [(and in-string (= c '\\')) (+= index 1)]
          [(= c '"') (set! in-string (not in-string))]
          [(and (not in-string) (= c '(')) (+= depth 1)]
          [(and (not in-string) (= c ')')) (-= depth 1)]
          [else unit])
        (+= index 1)))
    depth))

;; Occurrences of `needle` in `text`.
(define (occurrences [text : (& text str)] [needle : String]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [length : i64 (string.string-length needle)]
    (while (<= (+ index length) (string.string-length text))
      (if (string.eq (string.substring text index length) (& needle))
        (begin
          (+= count 1)
          (+= index length))
        (+= index 1)))
    count))

;; A batch name entry: this build's row hint, the length and the name.
(define (batch-name [name : String]) : String
  (str_cat.str-cat
    (producer.embedded-native-batch-int
      (tlci_core.tlci-host-callback-row-index (& name)))
    (producer.embedded-native-batch-int (string.string-length name))
    name))

(test
  status-chain-batches-constant-runs
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 5)]
    (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
    (set!
      (array-ref ops 1)
      (op-line "expr-var" (str_cat.str-cat (name-arg "x") " 1 0")))
    (set! (array-ref ops 2) (op-line "local-get" "k3 0 0"))
    (set! (array-ref ops 3) (op-line "expr-span" "3 4 -5"))
    (set! (array-ref ops 4) (op-line "expr-list-empty" "0 0 0"))
    (let
      [text : String (producer.embedded-native-ops-open-text ops 5)]
      (test.assert-i64-eq
        (open-parens (& text))
        10
        "every op still opens one pair")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        2
        "two constant runs")
      (test.assert-i64-eq
        (occurrences (& text) "(begin (begin")
        2
        "one empty pair per batched op after the first")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-local-get host session k3 0 0")
        1
        "the non-constant op stays a call")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (producer.embedded-native-escape-string
            (str_cat.str-cat
              (producer.embedded-native-batch-int 2)
              (batch-name "expr-list-empty")
              (batch-name "expr-var")
              (producer.embedded-native-batch-int 2)
              "0@@@1#A1xA1@")))
        1
        "the first run names each op once and indexes its names")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (producer.embedded-native-escape-string
            (str_cat.str-cat
              (producer.embedded-native-batch-int 2)
              (batch-name "expr-span")
              (batch-name "expr-list-empty")
              (producer.embedded-native-batch-int 2)
              "0A3A4a51@@@")))
        1
        "the second run")
      (test.assert-i64-eq
        (occurrences (& text) "[q0 :")
        1
        "the first run keeps its first op's status name")
      (test.assert-i64-eq
        (occurrences (& text) "[q2 :")
        1
        "the unbatched op keeps its own status name")
      (test.assert-i64-eq
        (occurrences (& text) "[q3 :")
        1
        "the second run keeps its first op's status name"))))

(test
  status-chain-leaves-lone-ops-as-calls
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 3)]
    (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
    (set! (array-ref ops 1) (op-line "local-get" "k1 0 0"))
    (set! (array-ref ops 2) (op-line "expr-list-empty" "0 0 0"))
    (let
      [text : String (producer.embedded-native-ops-open-text ops 3)]
      (test.assert-i64-eq (open-parens (& text)) 6 "three pairs")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        0
        "a run of one stays a call")
      (test.assert-i64-eq
        (occurrences
          (& text)
          "comptime-host-expr-list-empty host session 0 0 0")
        2
        "both lone ops are calls"))))

;; A run that would bind more distinct names than one batch may is split.
(test
  status-chain-splits-at-the-name-cap
  (let
    [count : i64 (+ tlci_core.tlci-run-ops-names-cap 1)]
    [ops : (__tl_dyn-array String) (__tl_make-array String count)]
    (for [index (iterator.range 0 count)]
      (set!
        (array-ref ops index)
        (op-line (str_cat.str-cat "op-" (string.int->string index)) "0 0 0")))
    (let
      [text : String (producer.embedded-native-ops-open-text ops count)]
      (test.assert-i64-eq
        (open-parens (& text))
        (* 2 count)
        "every op still opens one pair")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        1
        "one full batch")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (str_cat.str-cat
            "comptime-host-op-"
            (string.int->string tlci_core.tlci-run-ops-names-cap)))
        1
        "the op past the cap is left as its own call"))))