(import stdlib.checked_size)
(import stdlib.json)
(import stdlib.profile)
(import stdlib.serialize)
(import stdlib.test)

;; Spare storage is deliberately observable poison, including a corrupt nested
;; JSON value. Only the validated live prefix participates in sequence APIs.
(define (array-prefix) : json.JsonSeq
  (let
    [slots : (__tl_dyn-array json.Json) (__tl_make-array json.Json 4)]
    (begin
      (set! (array-ref slots 0) (json.JsonNumber "1"))
      (set! (array-ref slots 1) (json.JsonString "x"))
      (set!
        (array-ref slots 2)
        (json.JsonArray (box (json.JsonSeq (__tl_make-array json.Json 0) -1))))
      (json.JsonSeq slots 2))))

(define (member-prefix) : json.JsonMemberSeq
  (let
    [slots : (__tl_dyn-array json.JsonMember)
      (__tl_make-array json.JsonMember 4)]
    (begin
      (set! (array-ref slots 0) (json.JsonMember "x" (json.JsonNumber "1")))
      (set! (array-ref slots 1) (json.JsonMember "x" (json.JsonNumber "2")))
      (set!
        (array-ref slots 2)
        (json.JsonMember
          "poison"
          (json.JsonObject
            (box (json.JsonMemberSeq (__tl_make-array json.JsonMember 0) -1)))))
      (json.JsonMemberSeq slots 2))))

(define (assert-found [result : json.JsonLookup] [expected : String]) : unit
  (match result
    [(json.JsonFound value)
      (test.assert-string-eq
        (json.stringify value)
        expected
        "owned JSON lookup")]
    [(json.JsonMissing) (test.assert-true false "missing JSON lookup")]))

(define (assert-missing [result : json.JsonLookup]) : unit
  (match result
    [(json.JsonMissing) unit]
    [_ (test.assert-true false "lookup outside live prefix")]))

(define (check-arrays) : unit
  (let
    [items : json.JsonSeq (array-prefix)]
    [owned : json.JsonLookup (json.list-get-index-owned (& items) 1)]
    (begin
      (test.assert-i64-eq
        (json.list-count-ref (& items))
        2
        "borrowed live count")
      (set! (array-ref items.slots 1) json.JsonNull)
      (assert-found owned "\"x\"")
      (assert-found (json.list-get-index (array-prefix) 0) "1")
      (assert-missing (json.list-get-index (array-prefix) -1))
      (assert-missing (json.list-get-index (array-prefix) 2))
      (assert-missing (json.list-get-index (array-prefix) 9223372036854775807))
      (assert-missing (json.list-get-index-owned (& items) 2))
      (test.assert-i64-eq (json.list-count (array-prefix)) 2 "owned live count")
      (test.assert-string-eq
        (json.stringify-list (array-prefix))
        "1,\"x\""
        "live render")
      (test.assert-string-eq
        (json.stringify-list (json.list-reverse (array-prefix)))
        "\"x\",1"
        "reverse live prefix")
      (test.assert-string-eq
        (json.stringify-list (json.list-rest (array-prefix)))
        "\"x\""
        "rest live prefix")
      (test.assert-string-eq
        (json.stringify-list (json.list-cons json.JsonNull (array-prefix)))
        "null,1,\"x\""
        "prepend live prefix")
      (test.assert-string-eq
        (json.stringify-list (json.list-concat (array-prefix) (array-prefix)))
        "1,\"x\",1,\"x\""
        "concat live prefixes")
      (test.assert-string-eq
        (json.stringify-list (json.list-rest (json.list-empty)))
        ""
        "empty rest")
      (test.assert-string-eq
        (json.stringify-list (json.list-reverse (json.list-empty)))
        ""
        "empty reverse")
      (test.assert-string-eq
        (json.stringify-list
          (json.list-concat (json.list-empty) (json.list-empty)))
        ""
        "empty concat")
      (test.assert-string-eq
        (json.stringify-list (json.JsonSeq (__tl_make-array json.Json 3) 0))
        ""
        "empty live prefix with slack"))))

(define (check-members) : unit
  (let
    [items : json.JsonMemberSeq (member-prefix)]
    [key : String "x"]
    [owned : json.JsonLookup
      (json.member-list-get-value-owned (& items) (& key))]
    (begin
      (set! (array-ref items.slots 0) (json.JsonMember "x" json.JsonNull))
      (assert-found owned "1")
      (assert-found (json.member-list-get (member-prefix) (& key)) "1")
      (assert-found (json.member-list-get-owned (member-prefix) "x") "1")
      (assert-found
        (json.object-get (json.JsonObject (box (member-prefix))) (& key))
        "1")
      (assert-found
        (json.object-get-owned (json.JsonObject (box (member-prefix))) "x")
        "1")
      (assert-found
        (json.object-get-value-owned
          (json.JsonObject (box (member-prefix)))
          "x")
        "1")
      (test.assert-i64-eq
        (json.member-list-count (member-prefix))
        2
        "member live count")
      (test.assert-string-eq
        (json.stringify-members (member-prefix))
        "\"x\":1,\"x\":2"
        "duplicate order")
      (test.assert-string-eq
        (json.stringify-members (json.member-list-reverse (member-prefix)))
        "\"x\":2,\"x\":1"
        "reverse duplicates")
      (test.assert-string-eq
        (json.stringify-members
          (json.member-cons "head" json.JsonNull (member-prefix)))
        "\"head\":null,\"x\":1,\"x\":2"
        "member prepend")
      (test.assert-string-eq
        (json.stringify-members
          (json.member-list-reverse (json.member-list-empty)))
        ""
        "empty members")
      (test.assert-string-eq
        (json.stringify-members
          (json.JsonMemberSeq (__tl_make-array json.JsonMember 2) 0))
        ""
        "empty member prefix with slack"))))

(define (check-sizes) : unit
  (begin
    (test.assert-i64-eq (checked_size.add 0 0) 0 "zero size")
    (test.assert-i64-eq
      (checked_size.add 9223372036854775807 0)
      9223372036854775807
      "maximum add")
    (test.assert-i64-eq
      (checked_size.add 9223372036854775806 1)
      9223372036854775807
      "exact add boundary")
    (test.assert-i64-eq
      (checked_size.elements 0 9223372036854775807)
      0
      "empty large elements")
    (test.assert-i64-eq
      (checked_size.elements 9223372036854775807 0)
      9223372036854775807
      "zero-sized elements")
    (test.assert-i64-eq
      (checked_size.elements 9223372036854775807 1)
      9223372036854775807
      "maximum byte count")
    (test.assert-i64-eq
      (checked_size.elements (/ 9223372036854775807 24) 24)
      (/ 9223372036854775807 24)
      "exact element-byte boundary")))

(define (check-borrowed-count-allocation) : unit
  (let
    [items : json.JsonSeq (array-prefix)]
    [members : json.JsonMemberSeq (member-prefix)]
    [i : i64 0]
    [sum : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i 1000)
        (begin
          (set!
            sum
            (+
              sum
              (+
                (json.list-count-ref (& items))
                (json.member-list-count-ref (& members)))))
          (set! i (+ i 1))))
      (let
        [allocated : i64 (- (profile.alloc-total) before)]
        (begin
          (test.assert-i64-eq sum 4000 "borrowed counts")
          (test.assert-i64-eq allocated 0 "validation must not copy storage"))))))

(defstruct Sample
  (numbers (Array i64 2))
  (enabled bool))

(import (serialize.serialize json Sample) as sample_json)

(define finish-evaluations : i64
  0)

(define (array-once) : json.JsonSeq
  (begin
    (set! finish-evaluations (+ finish-evaluations 1))
    (array-prefix)))

(define (members-once) : json.JsonMemberSeq
  (begin
    (set! finish-evaluations (+ finish-evaluations 1))
    (member-prefix)))

(define (check-strategy) : unit
  (begin
    (set! finish-evaluations 0)
    (match (json.sequence-finish (array-once))
      [(json.JsonValue value)
        (test.assert-string-eq
          (json.stringify value)
          "[1,\"x\"]"
          "sequence finish")])
    (match (json.object-finish (members-once))
      [(json.JsonValue value)
        (test.assert-string-eq
          (json.stringify value)
          "{\"x\":1,\"x\":2}"
          "object finish")])
    (test.assert-i64-eq finish-evaluations 2 "finish arguments evaluated once")
    (test.assert-i64-eq
      (json.checked-live-prefix-length
        (begin
          (set! finish-evaluations (+ finish-evaluations 1))
          2)
        (begin
          (set! finish-evaluations (+ finish-evaluations 1))
          4))
      2
      "live-prefix macro result")
    (test.assert-i64-eq
      finish-evaluations
      4
      "validation operands evaluated once")
    (match (sample_json.encode (Sample (array 4 5) true))
      [(json.JsonValue value)
        (test.assert-string-eq
          (json.stringify value)
          "{\"numbers\":[4,5],\"enabled\":true}"
          "generated encoder")])
    (match (sample_json.decode (sample_json.encode (Sample (array 4 5) true)))
      [(sample_json.Ok value)
        (begin
          (test.assert-i64-eq (array-ref value.numbers 0) 4 "decoded first")
          (test.assert-i64-eq (array-ref value.numbers 1) 5 "decoded second")
          (test.assert-true value.enabled "decoded bool"))]
      [_ (test.assert-true false "generated JSON roundtrip")])))

(test arrays (check-arrays))

(test members (check-members))

(test sizes (check-sizes))

(test borrowed-count-allocation (check-borrowed-count-allocation))

(test strategy (check-strategy))

(define (main) : i64
  (begin
    (check-arrays)
    (check-members)
    (check-sizes)
    (check-borrowed-count-allocation)
    (check-strategy)
    42))