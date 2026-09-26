;; Every child constructs only safe, forgeable public values. The parent checks
;; the exact defined abort, so bounds faults, silent clamps and partial results
;; cannot masquerade as validation. No invalid-pointer macro probe is executed.
(import stdlib.checked_size)
(import stdlib.io)
(import stdlib.json)
(import stdlib.process)
(import stdlib.serialize)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector json.Json core) as values)
(import (vector.vector json.JsonMember core) as members)
(import (serialize.serialize json (type (__tl_dyn-array i64))) as array_json)

(defenum ProbeResult
  (ProbeOk)
  (ProbeError String))

(define (expect-object [value : json.Value]) : ProbeResult
  (begin
    (json.expect-object value "probe" ProbeError)
    ProbeOk))

(define (read-element [value : json.Value]) : ProbeResult
  (begin
    (json.sequence-element-value value 0 ProbeError)
    ProbeOk))

(define (read-field [value : json.Value]) : ProbeResult
  (begin
    (json.field-value value "x" ProbeError)
    ProbeOk))

(define (bad-length [shape : i64]) : i64
  (match shape
    [0 -1]
    [1 3]
    [2 1]
    [3 9223372036854775807]
    [_ (- (- 0 9223372036854775807) 1)]))

(define (capacity [shape : i64]) : i64
  (if (or (= shape 2) (= shape 3))
    0
    2))

(define (array-probe [operation : i64] [shape : i64]) : unit
  (let
    [items : json.JsonSeq
      (json.JsonSeq
        (__tl_make-array json.Json (capacity shape))
        (bad-length shape))]
    (begin
      (match operation
        [0
          (begin
            (json.list-count items)
            unit)]
        [1
          (begin
            (json.list-count-ref (& items))
            unit)]
        [2
          (begin
            (json.list-get-index items 0)
            unit)]
        [3
          (begin
            (json.list-get-index items -1)
            unit)]
        [4
          (begin
            (json.list-get-index-owned (& items) 0)
            unit)]
        [5
          (begin
            (json.list-get-index-owned (& items) -1)
            unit)]
        [6
          (begin
            (json.list-rest items)
            unit)]
        [7
          (begin
            (json.list-reverse items)
            unit)]
        [8
          (begin
            (json.list-cons json.JsonNull items)
            unit)]
        [9
          (begin
            (json.list-concat items (json.list-empty))
            unit)]
        [10
          (begin
            (json.list-concat (json.list-empty) items)
            unit)]
        [11
          (begin
            (json.stringify-list items)
            unit)]
        [12
          (begin
            (json.stringify-list-into items (text_buf.empty))
            unit)]
        [13
          (begin
            (json.stringify (json.JsonArray (box items)))
            unit)]
        [14
          (begin
            (json.sequence-finish items)
            unit)]
        [15
          (begin
            (array_json.decode (json.JsonValue (json.JsonArray (box items))))
            unit)]
        [16
          (begin
            (read-element (json.JsonValue (json.JsonArray (box items))))
            unit)]
        [_ (io.panic "invalid array probe")])
      unit)))

(define (member-probe [operation : i64] [shape : i64]) : unit
  (let
    [items : json.JsonMemberSeq
      (json.JsonMemberSeq
        (__tl_make-array json.JsonMember (capacity shape))
        (bad-length shape))]
    [key : String "x"]
    (begin
      (match operation
        [17
          (begin
            (json.member-list-count items)
            unit)]
        [18
          (begin
            (json.member-list-count-ref (& items))
            unit)]
        [19
          (begin
            (json.member-list-get items (& key))
            unit)]
        [20
          (begin
            (json.member-list-get-owned items key)
            unit)]
        [21
          (begin
            (json.member-list-get-value-owned (& items) (& key))
            unit)]
        [22
          (begin
            (json.member-list-reverse items)
            unit)]
        [23
          (begin
            (json.member-cons key json.JsonNull items)
            unit)]
        [24
          (begin
            (json.stringify-members items)
            unit)]
        [25
          (begin
            (json.stringify-members-into items (text_buf.empty))
            unit)]
        [26
          (begin
            (json.stringify (json.JsonObject (box items)))
            unit)]
        [27
          (begin
            (json.object-get (json.JsonObject (box items)) (& key))
            unit)]
        [28
          (begin
            (json.object-get-owned (json.JsonObject (box items)) key)
            unit)]
        [29
          (begin
            (json.object-get-value-owned (json.JsonObject (box items)) key)
            unit)]
        [30
          (begin
            (json.object-finish items)
            unit)]
        [31
          (begin
            (expect-object (json.JsonValue (json.JsonObject (box items))))
            unit)]
        [32
          (begin
            (read-field (json.JsonValue (json.JsonObject (box items))))
            unit)]
        [_ (io.panic "invalid member probe")])
      unit)))

(define (child [operation : i64] [shape : i64]) : i64
  (begin
    (cond
      [(< operation 17) (array-probe operation shape)]
      [(< operation 33) (member-probe operation shape)]
      [(= operation 33)
        (begin
          (json.vec-to-list
            (values.Vec
              (__tl_make-array json.Json (capacity shape))
              (bad-length shape)))
          unit)]
      [(= operation 34)
        (begin
          (json.member-vec-to-list
            (members.Vec
              (__tl_make-array json.JsonMember (capacity shape))
              (bad-length shape)))
          unit)]
      [(= operation 35)
        (begin
          (checked_size.add 9223372036854775807 1)
          unit)]
      [(= operation 36)
        (begin
          (checked_size.add -1 1)
          unit)]
      [(= operation 37)
        (begin
          (checked_size.add 1 -1)
          unit)]
      [(= operation 38)
        (begin
          (checked_size.elements (+ (/ 9223372036854775807 24) 1) 24)
          unit)]
      [(= operation 39)
        (begin
          (checked_size.elements -1 24)
          unit)]
      [(= operation 40)
        (begin
          (checked_size.elements 1 -1)
          unit)]
      [else (io.panic "invalid child probe")])
    0))

(define (main) : i64
  (if (= (io.arg-count) 3)
    (child (string.>int (io.arg 1)) (string.>int (io.arg 2)))
    (let
      [operation : i64 0]
      [shape : i64 0]
      (begin
        (while (< operation 41)
          (begin
            (set! shape 0)
            (while (<
              shape
              (if (< operation 35)
                5
                1))
              (begin
                (unless
                  (process.result-output-eq?
                    (process.output
                      (process.command
                        (io.arg 0)
                        (process.args-cons
                          (string.int->string operation)
                          (process.args-single (string.int->string shape)))))
                    134
                    ""
                    (if (< operation 35)
                      "json: invalid sequence length\n"
                      "size: arithmetic overflow\n"))
                  (begin
                    (io.println
                      "failed JSON boundary probe {}/{}"
                      operation
                      shape)
                    (return 1)))
                (set! shape (+ shape 1))))
            (set! operation (+ operation 1))))
        42))))