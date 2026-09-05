(import stdlib.byte_buf)
(import stdlib.net.http_trailer_policy as trailer_policy)
(import stdlib.net.http_types)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (name [spelling : String]) : http_types.HttpHeaderName
  (http_types.HttpHeaderName (byte_buf.from-string spelling)))

(define (field
  [spelling : String]
  [value : String]
  [sensitivity : http_types.HttpHeaderSensitivity]) : http_types.HttpHeaderField
  (http_types.HttpHeaderField
    (name spelling)
    (http_types.HttpHeaderValue (byte_buf.from-string value))
    sensitivity))

(define (public-field [spelling : String] [value : String]) : http_types.HttpHeaderField
  (field spelling value (http_types.HttpHeaderPublic)))

(define (sensitive-field [spelling : String] [value : String]) : http_types.HttpHeaderField
  (field spelling value (http_types.HttpHeaderSensitive)))

(define (field-with-final-byte
  [spelling : String]
  [prefix : String]
  [final-byte : u8]) : http_types.HttpHeaderField
  (let
    [value : byte_buf.ByteBuf (byte_buf.from-string prefix)]
    (http_types.HttpHeaderField
      (name spelling)
      (http_types.HttpHeaderValue (byte_buf.push value final-byte))
      (http_types.HttpHeaderPublic))))

(define (policy-add-ok
  [policy : trailer_policy.HttpTrailerPolicy]
  [spelling : String]
  [sensitivity : http_types.HttpHeaderSensitivity]
  [multiplicity : trailer_policy.HttpTrailerMultiplicity]) : trailer_policy.HttpTrailerPolicy
  (match (trailer_policy.trailer-policy-add
    policy
    (name spelling)
    sensitivity
    multiplicity)
    [(trailer_policy.HttpTrailerPolicyAddErr _)
      (begin
        (fail "expected trailer policy addition to succeed")
        (trailer_policy.trailer-policy-empty))]
    [(trailer_policy.HttpTrailerPolicyAddOk next) next]))

(define (sample-policy) : trailer_policy.HttpTrailerPolicy
  (let
    [policy : trailer_policy.HttpTrailerPolicy
      (policy-add-ok
        (trailer_policy.trailer-policy-empty)
        "X-One"
        (http_types.HttpHeaderPublic)
        (trailer_policy.HttpTrailerAtMostOnce))]
    (begin
      (set!
        policy
        (policy-add-ok
          policy
          "X-List"
          (http_types.HttpHeaderPublic)
          (trailer_policy.HttpTrailerRepeatableList)))
      (set!
        policy
        (policy-add-ok
          policy
          "X-Secret"
          (http_types.HttpHeaderSensitive)
          (trailer_policy.HttpTrailerRepeatableSeparate)))
      policy)))

(define (headers-push
  [headers : http_types.HttpHeaders]
  [next : http_types.HttpHeaderField]) : http_types.HttpHeaders
  (http_types.headers-append headers next))

(define (declared-add
  [declared : http_types.HttpHeaderNameSet]
  [spelling : String]) : http_types.HttpHeaderNameSet
  (let
    [bytes : (& spelling bytes) (byte_buf.str-as-bytes (& spelling))]
    (http_types.header-name-set-add declared bytes)))

(define (validation-ok?
  [policy : (& policy trailer_policy.HttpTrailerPolicy)]
  [headers : (& headers http_types.HttpHeaders)]
  [declared : (& declared http_types.HttpHeaderNameSet)]
  [require-declared : bool]
  [limits : (& limits http_types.HttpHeadLimits)]) : bool
  (match (trailer_policy.validate-trailer-fields
    policy
    headers
    declared
    require-declared
    limits)
    [(trailer_policy.HttpTrailerValidationOk) true]
    [(trailer_policy.HttpTrailerValidationErr _) false]))

(define (mixed-case-name [source : String]) : http_types.HttpHeaderName
  (let
    [input : (& source bytes) (byte_buf.str-as-bytes (& source))]
    [out : byte_buf.ByteBuf
      (byte_buf.with-capacity (byte_buf.bytes-length input))]
    [index : i64 0]
    (begin
      (while (< index (byte_buf.bytes-length input))
        (let
          [byte : u8 (byte_buf.bytes-ref input index)]
          [code : i64 (cast byte : i64)]
          (begin
            (set!
              out
              (byte_buf.push
                out
                (if (and (= (% index 2) 0) (>= code 97) (<= code 122))
                  (cast (- code 32) : u8)
                  byte)))
            (set! index (+ index 1)))))
      (http_types.HttpHeaderName out))))

(define (assert-policy-construction) : unit
  (begin
    (let
      [empty : trailer_policy.HttpTrailerPolicy
        (trailer_policy.trailer-policy-empty)]
      (test.assert-i64-eq
        (trailer_policy.trailer-policy-len (& empty))
        0
        "empty policy approves nothing"))
    (match (trailer_policy.trailer-policy-new
      (trailer_policy.HttpTrailerPolicyLimits -1 1 1))
      [(trailer_policy.HttpTrailerPolicyNewErr error)
        (match error.kind
          [(trailer_policy.HttpTrailerInvalidPolicyLimits) unit]
          [_ (fail "invalid policy limits error kind")])]
      [_ (fail "negative policy limit accepted")])
    (let
      [policy : trailer_policy.HttpTrailerPolicy (sample-policy)]
      (begin
        (test.assert-i64-eq
          (trailer_policy.trailer-policy-len (& policy))
          3
          "policy insertion count")
        (let
          [entry : (& policy trailer_policy.HttpTrailerPolicyEntry)
            (trailer_policy.trailer-policy-ref (& policy) 0)]
          [actual : String
            (byte_buf.bytes-to-string
              (http_types.header-name-bytes (& entry.name)))]
          [expected : String "x-one"]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "policy name normalized"))
        (let
          [lookup : String "X-oNe"]
          [lookup-bytes : (& lookup bytes) (byte_buf.str-as-bytes (& lookup))]
          (test.assert-i64-eq
            (trailer_policy.trailer-policy-find (& policy) lookup-bytes)
            0
            "policy lookup folds ASCII case"))
        (match (trailer_policy.trailer-policy-add
          policy
          (name "x-OnE")
          (http_types.HttpHeaderPublic)
          (trailer_policy.HttpTrailerAtMostOnce))
          [(trailer_policy.HttpTrailerPolicyAddErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerDuplicatePolicyName) unit]
              [_ (fail "duplicate policy error kind")])]
          [_ (fail "case-insensitive policy duplicate accepted")])))))

(define (assert-forbidden-table) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (trailer_policy.forbidden-trailer-name-count))
        (let
          [spelling : String (trailer_policy.forbidden-trailer-name index)]
          [mixed : http_types.HttpHeaderName (mixed-case-name spelling)]
          (begin
            (test.assert-true
              (trailer_policy.trailer-name-forbidden? (& mixed))
              "mixed-case forbidden name lookup")
            (match (trailer_policy.trailer-policy-add
              (trailer_policy.trailer-policy-empty)
              mixed
              (http_types.HttpHeaderSensitive)
              (trailer_policy.HttpTrailerRepeatableSeparate))
              [(trailer_policy.HttpTrailerPolicyAddErr error)
                (match error.kind
                  [(trailer_policy.HttpTrailerForbiddenName) unit]
                  [_ (fail "forbidden policy name error kind")])]
              [_ (fail "forbidden trailer name admitted")])
            (set! index (+ index 1)))))
      unit)))

(define (assert-policy-limits) : unit
  (begin
    (match (trailer_policy.trailer-policy-add
      (trailer_policy.trailer-policy-empty)
      (name "bad name")
      (http_types.HttpHeaderPublic)
      (trailer_policy.HttpTrailerAtMostOnce))
      [(trailer_policy.HttpTrailerPolicyAddErr error)
        (match error.kind
          [(trailer_policy.HttpTrailerInvalidPolicyName) unit]
          [_ (fail "invalid policy name error kind")])]
      [_ (fail "invalid policy name accepted")])
    (match (trailer_policy.trailer-policy-new
      (trailer_policy.HttpTrailerPolicyLimits 2 4 8))
      [(trailer_policy.HttpTrailerPolicyNewErr _)
        (fail "valid policy limits rejected")]
      [(trailer_policy.HttpTrailerPolicyNewOk policy)
        (match (trailer_policy.trailer-policy-add
          policy
          (name "x-long")
          (http_types.HttpHeaderPublic)
          (trailer_policy.HttpTrailerAtMostOnce))
          [(trailer_policy.HttpTrailerPolicyAddErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerPolicyNameTooLong) unit]
              [_ (fail "policy name length error kind")])]
          [_ (fail "overlong policy name accepted")])])
    (match (trailer_policy.trailer-policy-new
      (trailer_policy.HttpTrailerPolicyLimits 2 8 5))
      [(trailer_policy.HttpTrailerPolicyNewErr _)
        (fail "total-byte policy limits rejected")]
      [(trailer_policy.HttpTrailerPolicyNewOk policy)
        (let
          [one : trailer_policy.HttpTrailerPolicy
            (policy-add-ok
              policy
              "x-a"
              (http_types.HttpHeaderPublic)
              (trailer_policy.HttpTrailerAtMostOnce))]
          (match (trailer_policy.trailer-policy-add
            one
            (name "x-b")
            (http_types.HttpHeaderPublic)
            (trailer_policy.HttpTrailerAtMostOnce))
            [(trailer_policy.HttpTrailerPolicyAddErr error)
              (match error.kind
                [(trailer_policy.HttpTrailerPolicyNameBytesExceeded) unit]
                [_ (fail "policy total-name error kind")])]
            [_ (fail "policy total-name limit exceeded")]))])
    (match (trailer_policy.trailer-policy-new
      (trailer_policy.HttpTrailerPolicyLimits 1 8 8))
      [(trailer_policy.HttpTrailerPolicyNewErr _)
        (fail "entry-count policy limits rejected")]
      [(trailer_policy.HttpTrailerPolicyNewOk policy)
        (let
          [one : trailer_policy.HttpTrailerPolicy
            (policy-add-ok
              policy
              "x-a"
              (http_types.HttpHeaderPublic)
              (trailer_policy.HttpTrailerAtMostOnce))]
          (match (trailer_policy.trailer-policy-add
            one
            (name "x-b")
            (http_types.HttpHeaderPublic)
            (trailer_policy.HttpTrailerAtMostOnce))
            [(trailer_policy.HttpTrailerPolicyAddErr error)
              (match error.kind
                [(trailer_policy.HttpTrailerTooManyPolicyEntries) unit]
                [_ (fail "policy entry-count error kind")])]
            [_ (fail "policy entry-count limit exceeded")]))])
    (test.assert-i64-eq
      (trailer_policy.bounded-add 9223372036854775807 1 9223372036854775807)
      -1
      "policy checked addition boundary")
    (test.assert-i64-eq
      (http_types.bounded-field-length-add
        9223372036854775807
        1
        9223372036854775807)
      -1
      "typed-field checked addition boundary")
    (test.assert-i64-eq
      (http_types.field-offset-add 9223372036854775807 1)
      9223372036854775807
      "typed-field offset saturation")))

(define (assert-declaration-cross-product) : unit
  (let
    [policy : trailer_policy.HttpTrailerPolicy (sample-policy)]
    [approved : http_types.HttpHeaders
      (headers-push (http_types.headers-empty) (public-field "X-One" "ok"))]
    [unapproved : http_types.HttpHeaders
      (headers-push (http_types.headers-empty) (public-field "X-Other" "ok"))]
    [declared : http_types.HttpHeaderNameSet
      (declared-add (http_types.header-name-set-empty) "x-one")]
    [empty-declared : http_types.HttpHeaderNameSet
      (http_types.header-name-set-empty)]
    [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
    (begin
      (let
        [empty-policy : trailer_policy.HttpTrailerPolicy
          (trailer_policy.trailer-policy-empty)]
        [empty-fields : http_types.HttpHeaders (http_types.headers-empty)]
        (begin
          (test.assert-true
            (validation-ok?
              (& empty-policy)
              (& empty-fields)
              (& empty-declared)
              false
              (& limits))
            "empty default accepts empty trailers")
          (match (trailer_policy.validate-response-trailer-fields
            (& empty-policy)
            (& approved)
            (& declared)
            (& limits))
            [(trailer_policy.HttpTrailerValidationErr error)
              (match error.kind
                [(trailer_policy.HttpTrailerUnapprovedName) unit]
                [_ (fail "empty policy rejection kind")])]
            [_ (fail "empty policy approved an extension")])))
      (test.assert-true
        (match (trailer_policy.validate-request-trailer-fields
          (& policy)
          (& approved)
          (& declared)
          (& limits))
          [(trailer_policy.HttpTrailerValidationOk) true]
          [(trailer_policy.HttpTrailerValidationErr _) false])
        "approved declared trailer")
      (test.assert-false
        (validation-ok?
          (& policy)
          (& approved)
          (& empty-declared)
          true
          (& limits))
        "approved undeclared trailer")
      (test.assert-false
        (validation-ok? (& policy) (& unapproved) (& declared) true (& limits))
        "unapproved declared trailer")
      (test.assert-false
        (validation-ok?
          (& policy)
          (& unapproved)
          (& empty-declared)
          true
          (& limits))
        "unapproved undeclared trailer")
      (test.assert-true
        (match (trailer_policy.validate-response-trailer-fields
          (& policy)
          (& approved)
          (& empty-declared)
          (& limits))
          [(trailer_policy.HttpTrailerValidationOk) true]
          [(trailer_policy.HttpTrailerValidationErr _) false])
        "response validation does not require declaration"))))

(define (assert-multiplicity-and-preservation) : unit
  (let
    [policy : trailer_policy.HttpTrailerPolicy (sample-policy)]
    [declared : http_types.HttpHeaderNameSet (http_types.header-name-set-empty)]
    [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
    [repeatable : http_types.HttpHeaders (http_types.headers-empty)]
    (begin
      (set! repeatable (headers-push repeatable (public-field "X-List" "a")))
      (set! repeatable (headers-push repeatable (public-field "x-list" "b")))
      (set!
        repeatable
        (headers-push repeatable (sensitive-field "X-Secret" "first-secret")))
      (set!
        repeatable
        (headers-push repeatable (sensitive-field "x-secret" "second-secret")))
      (test.assert-true
        (validation-ok? (& policy) (& repeatable) (& declared) false (& limits))
        "both repeatable multiplicities")
      (let
        [first : (& repeatable http_types.HttpHeaderField)
          (http_types.headers-ref (& repeatable) 0)]
        [last : (& repeatable http_types.HttpHeaderField)
          (http_types.headers-ref (& repeatable) 3)]
        [first-name : String
          (byte_buf.bytes-to-string
            (http_types.header-name-bytes (& first.name)))]
        [last-value : String
          (byte_buf.bytes-to-string
            (http_types.header-value-bytes (& last.value)))]
        [expected-name : String "X-List"]
        [expected-value : String "second-secret"]
        (begin
          (test.assert-string-eq
            (& first-name)
            (& expected-name)
            "original trailer spelling preserved")
          (test.assert-string-eq
            (& last-value)
            (& expected-value)
            "trailer value and order preserved")))
      (let
        [once : http_types.HttpHeaders (http_types.headers-empty)]
        (begin
          (set! once (headers-push once (public-field "X-One" "a")))
          (set! once (headers-push once (public-field "x-one" "b")))
          (match (trailer_policy.validate-trailer-fields
            (& policy)
            (& once)
            (& declared)
            false
            (& limits))
            [(trailer_policy.HttpTrailerValidationErr error)
              (begin
                (test.assert-i64-eq error.index 1 "duplicate field index")
                (match error.kind
                  [(trailer_policy.HttpTrailerDuplicateField) unit]
                  [_ (fail "at-most-once error kind")]))]
            [_ (fail "at-most-once duplicate accepted")]))))))

(define (assert-sensitivity-and-shape) : unit
  (let
    [policy : trailer_policy.HttpTrailerPolicy (sample-policy)]
    [declared : http_types.HttpHeaderNameSet (http_types.header-name-set-empty)]
    [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
    [wrong-secret : http_types.HttpHeaders
      (headers-push
        (http_types.headers-empty)
        (public-field "X-Secret" "must-not-appear-in-error"))]
    (begin
      (match (trailer_policy.validate-trailer-fields
        (& policy)
        (& wrong-secret)
        (& declared)
        false
        (& limits))
        [(trailer_policy.HttpTrailerValidationErr error)
          (match error.kind
            [(trailer_policy.HttpTrailerSensitivityMismatch) unit]
            [_ (fail "extension sensitivity mismatch kind")])]
        [_ (fail "secret extension sensitivity downgraded")])
      (let
        [authorization : http_types.HttpHeaderField
          (public-field "Authorization" "do-not-retain")]
        (match (http_types.validate-typed-field (& authorization) 12 (& limits))
          [(http_types.HttpTypedFieldErr error)
            (begin
              (test.assert-false error.poison-connection "typed field is local")
              (match error.kind
                [(http_types.HttpSensitiveHeaderMustBeMarked) unit]
                [_ (fail "known sensitivity error kind")]))]
          [_ (fail "public Authorization typed field accepted")]))
      (let
        [bad : http_types.HttpHeaders
          (headers-push
            (http_types.headers-empty)
            (public-field "bad name" "value"))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& bad)
          (& declared)
          false
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidField head-kind)
                (match head-kind
                  [(http_types.HttpInvalidFieldName) unit]
                  [_ (fail "nested typed-field name kind")])]
              [_ (fail "typed-field wrapper error kind")])]
          [_ (fail "malformed typed field accepted")]))
      (let
        [bad-ows : http_types.HttpHeaders
          (headers-push
            (http_types.headers-empty)
            (public-field "X-One" " leading"))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& bad-ows)
          (& declared)
          false
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidField head-kind)
                (match head-kind
                  [(http_types.HttpNonCanonicalFieldValueWhitespace) unit]
                  [_ (fail "typed-field OWS kind")])]
              [_ (fail "typed-field OWS wrapper kind")])]
          [_ (fail "noncanonical typed field accepted")]))
      (let
        [bad-nul : http_types.HttpHeaderField
          (field-with-final-byte "X-One" "safe-prefix" (cast 0 : u8))]
        (match (http_types.validate-typed-field (& bad-nul) 7 (& limits))
          [(http_types.HttpTypedFieldErr error)
            (match error.kind
              [(http_types.HttpNulByte) unit]
              [_ (fail "typed-field NUL kind")])]
          [_ (fail "typed-field NUL accepted")]))
      (let
        [bad-control : http_types.HttpHeaderField
          (field-with-final-byte "X-One" "safe-prefix" (cast 1 : u8))]
        (match (http_types.validate-typed-field (& bad-control) 7 (& limits))
          [(http_types.HttpTypedFieldErr error)
            (match error.kind
              [(http_types.HttpInvalidControlByte) unit]
              [_ (fail "typed-field control kind")])]
          [_ (fail "typed-field control accepted")]))
      (let
        [forbidden : http_types.HttpHeaders
          (headers-push
            (http_types.headers-empty)
            (public-field "Content-Length" "1"))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& forbidden)
          (& declared)
          false
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerForbiddenName) unit]
              [_ (fail "forbidden typed trailer kind")])]
          [_ (fail "forbidden typed trailer accepted")])))))

(define (assert-field-limits-and-corruption) : unit
  (let
    [policy : trailer_policy.HttpTrailerPolicy (sample-policy)]
    [declared : http_types.HttpHeaderNameSet (http_types.header-name-set-empty)]
    [two : http_types.HttpHeaders (http_types.headers-empty)]
    (begin
      (set! two (headers-push two (public-field "X-List" "a")))
      (set! two (headers-push two (public-field "X-List" "b")))
      (let
        [count-limits : http_types.HttpHeadLimits
          (http_types.HttpHeadLimits 64 32 1 16 16)]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& two)
          (& declared)
          false
          (& count-limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerTooManyFields) unit]
              [_ (fail "trailer field-count kind")])]
          [_ (fail "trailer field-count limit exceeded")]))
      (let
        [total-limits : http_types.HttpHeadLimits
          (http_types.HttpHeadLimits 16 12 4 6 1)]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& two)
          (& declared)
          false
          (& total-limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (begin
              (test.assert-i64-eq error.index 1 "total-byte failure index")
              (match error.kind
                [(trailer_policy.HttpTrailerFieldBytesExceeded) unit]
                [_ (fail "trailer total-byte kind")]))]
          [_ (fail "trailer total-byte limit exceeded")]))
      (let
        [name-limits : http_types.HttpHeadLimits
          (http_types.HttpHeadLimits 32 16 2 4 8)]
        [one : http_types.HttpHeaders
          (headers-push (http_types.headers-empty) (public-field "X-One" "a"))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& one)
          (& declared)
          false
          (& name-limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidField head-kind)
                (match head-kind
                  [(http_types.HttpNameTooLong) unit]
                  [_ (fail "trailer name-limit head kind")])]
              [_ (fail "trailer name-limit wrapper kind")])]
          [_ (fail "trailer name limit exceeded")]))
      (let
        [value-limits : http_types.HttpHeadLimits
          (http_types.HttpHeadLimits 32 16 2 8 1)]
        [one : http_types.HttpHeaders
          (headers-push (http_types.headers-empty) (public-field "X-One" "ab"))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& one)
          (& declared)
          false
          (& value-limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidField head-kind)
                (match head-kind
                  [(http_types.HttpValueTooLong) unit]
                  [_ (fail "trailer value-limit head kind")])]
              [_ (fail "trailer value-limit wrapper kind")])]
          [_ (fail "trailer value limit exceeded")]))
      (let
        [line-limits : http_types.HttpHeadLimits
          (http_types.HttpHeadLimits 16 6 2 5 1)]
        [one : http_types.HttpHeaders
          (headers-push (http_types.headers-empty) (public-field "X-One" ""))]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& one)
          (& declared)
          false
          (& line-limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidField head-kind)
                (match head-kind
                  [(http_types.HttpLineTooLong) unit]
                  [_ (fail "trailer line-limit head kind")])]
              [_ (fail "trailer line-limit wrapper kind")])]
          [_ (fail "trailer line limit exceeded")]))
      (let
        [corrupt-fields : http_types.HttpHeaders
          (http_types.HttpHeaders
            (__tl_make-array http_types.HttpHeaderField 0)
            1)]
        [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
        (match (trailer_policy.validate-trailer-fields
          (& policy)
          (& corrupt-fields)
          (& declared)
          false
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidFieldCollection) unit]
              [_ (fail "corrupt field collection kind")])]
          [_ (fail "corrupt field collection accepted")]))
      (let
        [approved : http_types.HttpHeaders
          (headers-push (http_types.headers-empty) (public-field "X-One" "ok"))]
        [corrupt-declared : http_types.HttpHeaderNameSet
          (http_types.HttpHeaderNameSet (__tl_make-array byte_buf.ByteBuf 0) 1)]
        [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
        (match (trailer_policy.validate-request-trailer-fields
          (& policy)
          (& approved)
          (& corrupt-declared)
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerInvalidDeclaredNames) unit]
              [_ (fail "corrupt declared-name set kind")])]
          [_ (fail "corrupt declared-name set accepted")]))
      (let
        [corrupt-policy : trailer_policy.HttpTrailerPolicy
          (trailer_policy.HttpTrailerPolicy
            (__tl_make-array trailer_policy.HttpTrailerPolicyEntry 0)
            1
            0
            (trailer_policy.default-trailer-policy-limits))]
        [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
        (match (trailer_policy.validate-trailer-fields
          (& corrupt-policy)
          (& two)
          (& declared)
          false
          (& limits))
          [(trailer_policy.HttpTrailerValidationErr error)
            (match error.kind
              [(trailer_policy.HttpTrailerCorruptPolicy) unit]
              [_ (fail "corrupt policy kind")])]
          [_ (fail "corrupt policy accepted")])))))

(define (main) : i64
  (begin
    (assert-policy-construction)
    (assert-forbidden-table)
    (assert-policy-limits)
    (assert-declaration-cross-product)
    (assert-multiplicity-and-preservation)
    (assert-sensitivity-and-shape)
    (assert-field-limits-and-corruption)
    42))