;; compiler_tlci_native_producer_tests.tl - the producer's `run-ops` batching:
;; which op lines become batch tokens and how the status chain renders a run
;; of them. The host side of the batch format is covered by
;; src/tests/comptime_host_smoke.tl, and the gates that compile every stdlib
;; macro through both routes cover the end-to-end expansions. Refs #8274.
(import compiler_tlci_native_producer as producer)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)
(import tlci_core)

;; The batch tokens of `line`, or "none" when it is not batchable.
(define (batch-tokens [line : String]) : String
  (match (producer.embedded-native-batch-op (& line))
    [(producer.EmbeddedNativeBatchOpSome name tokens)
      (str_cat.str-cat name tokens)]
    [(producer.EmbeddedNativeBatchOpNone) "none"]))

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
  (begin
    (test.assert-owned-string-eq
      (batch-tokens (op-line "expr-span" "3 14 -21474836480"))
      "expr-span 3 14 -21474836480"
      "integer immediates stay as they are")
    (test.assert-owned-string-eq
      (batch-tokens
        (op-line "expr-var" (str_cat.str-cat (name-arg "value") " 5 0")))
      "expr-var #5:value 5 0"
      "a name argument carries its bytes")
    (test.assert-owned-string-eq
      (batch-tokens
        (op-line
          "string-value"
          (str_cat.str-cat (name-arg "a\\\"b\\\\c\\n d") " 8 0")))
      "string-value #8:a\"b\\c\n d 8 0"
      "escapes are undone and the byte length counts raw bytes")
    (test.assert-owned-string-eq
      (batch-tokens
        (op-line
          "type-ref"
          (str_cat.str-cat "1 " (str_cat.str-cat (name-arg "r") " 1"))))
      "type-ref 1 #1:r 1"
      "a name argument may sit in the middle position")))

(test
  batch-op-rejects-non-constant-shapes
  (begin
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
      "only host calls are batched")))

;; The number of `(` minus `)` in `text` outside string literals.
(define (open-parens [text : (& text str)]) : i64
  (let
    [depth : i64 0]
    [index : i64 0]
    [in-string : bool false]
    (begin
      (while (< index (string.string-length text))
        (let
          [c : char (string.string-ref text index)]
          (begin
            (cond
              [(and in-string (= c '\\')) (set! index (+ index 1))]
              [(= c '"') (set! in-string (not in-string))]
              [(and (not in-string) (= c '(')) (set! depth (+ depth 1))]
              [(and (not in-string) (= c ')')) (set! depth (- depth 1))]
              [else unit])
            (set! index (+ index 1)))))
      depth)))

;; Occurrences of `needle` in `text`.
(define (occurrences [text : (& text str)] [needle : String]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [length : i64 (string.string-length needle)]
    (begin
      (while (<= (+ index length) (string.string-length text))
        (if (string.eq (string.substring text index length) (& needle))
          (begin
            (set! count (+ count 1))
            (set! index (+ index length)))
          (set! index (+ index 1))))
      count)))

(test
  status-chain-batches-constant-runs
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 5)]
    (begin
      (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
      (set!
        (array-ref ops 1)
        (op-line "expr-var" (str_cat.str-cat (name-arg "x") " 1 0")))
      (set! (array-ref ops 2) (op-line "local-get" "k3 0 0"))
      (set! (array-ref ops 3) (op-line "expr-span" "3 4 -5"))
      (set! (array-ref ops 4) (op-line "expr-list-empty" "0 0 0"))
      (let
        [text : String (producer.embedded-native-ops-open-text ops 5)]
        (begin
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
              "2 expr-list-empty expr-var 2 0 0 0 0 1 #1:x 1 0")
            1
            "the first run names each op once and indexes its names")
          (test.assert-i64-eq
            (occurrences
              (& text)
              "2 expr-span expr-list-empty 2 0 3 4 -5 1 0 0 0")
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
            "the second run keeps its first op's status name"))))))

(test
  status-chain-leaves-lone-ops-as-calls
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 3)]
    (begin
      (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
      (set! (array-ref ops 1) (op-line "local-get" "k1 0 0"))
      (set! (array-ref ops 2) (op-line "expr-list-empty" "0 0 0"))
      (let
        [text : String (producer.embedded-native-ops-open-text ops 3)]
        (begin
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
            "both lone ops are calls"))))))

;; A run that would bind more distinct names than one batch may is split.
(test
  status-chain-splits-at-the-name-cap
  (let
    [count : i64 (+ tlci_core.tlci-run-ops-names-cap 1)]
    [ops : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref ops index)
            (op-line (str_cat.str-cat "op-" (string.int->string index)) "0 0 0"))
          (set! index (+ index 1))))
      (let
        [text : String (producer.embedded-native-ops-open-text ops count)]
        (begin
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
            "the op past the cap is left as its own call"))))))