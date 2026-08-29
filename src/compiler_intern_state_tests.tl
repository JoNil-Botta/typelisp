;; Focused ownership, reset, and growth coverage for session-owned syntax ids.
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import stdlib.test)

(define (intern-identity-test-session [state : (& state ci.InternCompatState)]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (ci.intern-source-name-session-handle-from-state state)))

(define (intern-template-record-source-or
  [session : cis.InternStructuralSessionHandle]
  [raw : i64]
  [fallback : i64]) : i64
  (match (cis.intern-structural-session-template-source-record-for-raw
    session
    raw)
    [(cis.InternMaybeTemplateSourceRecord.Some record) record.source-name-id]
    [(cis.InternMaybeTemplateSourceRecord.No) fallback]))

(define (intern-fresh-record-components-match?
  [session : cis.InternStructuralSessionHandle]
  [raw : i64]
  [ordinal : i64]
  [source-name-id : i64]) : bool
  (match (cis.intern-structural-session-fresh-local-record-for-raw session raw)
    [(cis.InternMaybeFreshLocalRecord.Some record)
      (and (= record.ordinal ordinal) (= record.source-name-id source-name-id))]
    [(cis.InternMaybeFreshLocalRecord.No) false]))

(test
  compiler-intern-template-fresh-record-ownership
  (let
    [left : ci.InternCompatState (ci.intern-compat-state-new)]
    [right : ci.InternCompatState (ci.intern-compat-state-new)]
    [left-source : i64 (ci.intern-compat-state-intern (&mut left) "left-name")]
    [right-source : i64
      (ci.intern-compat-state-intern (&mut right) "right-name")]
    [left-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& left))]
    [right-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& right))]
    [template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        left-session
        left-source)]
    [template-again : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        left-session
        left-source)]
    [fresh : cis.InternFreshLocalIdentity
      (cis.intern-structural-session-fresh-local-identity
        left-session
        17
        left-source)]
    [right-template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        right-session
        right-source)]
    [malformed-template : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-key
          left-session
          (ci.intern-structural-kind-template-source)
          1
          0
          left-source))]
    [malformed-fresh : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-key
          left-session
          (ci.intern-structural-kind-fresh-local)
          17
          1
          left-source))]
    (begin
      (test.assert-i64-eq
        (cis.intern-template-source-identity-size)
        8
        "template identity remains one machine word")
      (test.assert-i64-eq
        (cis.intern-fresh-local-identity-size)
        8
        "fresh-local identity remains one machine word")
      (test.assert-i64-eq
        (cis.intern-template-source-identity-raw template)
        (cis.intern-template-source-identity-raw template-again)
        "template records canonicalize identical components")
      (test.assert-i64-eq
        (intern-template-record-source-or
          left-session
          (cis.intern-template-source-identity-raw template)
          -1)
        left-source
        "template record round-trips its source component")
      (test.assert-true
        (intern-fresh-record-components-match?
          left-session
          (cis.intern-fresh-local-identity-raw fresh)
          17
          left-source)
        "fresh-local record round-trips ordinal and source")
      (test.assert-false
        (cis.intern-structural-session-template-source-id?
          right-session
          (cis.intern-template-source-identity-raw template))
        "template decoder rejects a wrong owner")
      (test.assert-false
        (cis.intern-structural-session-fresh-local-id?
          left-session
          (cis.intern-template-source-identity-raw template))
        "fresh-local decoder rejects the template kind")
      (test.assert-false
        (cis.intern-structural-session-template-source-id?
          left-session
          malformed-template)
        "template decoder rejects a populated reserved lane")
      (test.assert-false
        (cis.intern-structural-session-fresh-local-id?
          left-session
          malformed-fresh)
        "fresh-local decoder rejects a populated reserved lane")
      (test.assert-false
        (=
          (cis.intern-template-source-identity-raw template)
          (cis.intern-template-source-identity-raw right-template))
        "different sessions produce distinct process-local handles"))))

(test
  compiler-intern-fresh-local-deliberate-hash-collision
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "collision-name")]
    [session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    ;; The initial map has 512 slots. Its lower hash bits for equal kind,
    ;; middle, and right repeat when this left/ordinal lane differs by 512.
    [first : i64
      (cis.intern-fresh-local-identity-raw
        (cis.intern-structural-session-fresh-local-identity session 0 source))]
    [colliding : i64
      (cis.intern-fresh-local-identity-raw
        (cis.intern-structural-session-fresh-local-identity session 512 source))]
    (begin
      (test.assert-false (= first colliding) "colliding records do not alias")
      (test.assert-true
        (intern-fresh-record-components-match? session first 0 source)
        "first colliding record remains reachable")
      (test.assert-true
        (intern-fresh-record-components-match? session colliding 512 source)
        "linear probing retains the colliding record"))))

(test
  compiler-intern-template-fresh-stale-reset
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "reset-name")]
    [stale-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    [stale-template : i64
      (cis.intern-template-source-identity-raw
        (cis.intern-structural-session-template-source-identity
          stale-session
          source))]
    (begin
      (ci.intern-compat-state-reset! (&mut state))
      (let
        [next-source : i64
          (ci.intern-compat-state-intern (&mut state) "reset-name")]
        [next-session : cis.InternStructuralSessionHandle
          (intern-identity-test-session (& state))]
        [next-template : i64
          (cis.intern-template-source-identity-raw
            (cis.intern-structural-session-template-source-identity
              next-session
              next-source))]
        (begin
          (test.assert-false
            (cis.intern-structural-session-valid? stale-session)
            "reset invalidates the captured structural session")
          (test.assert-i64-eq
            (intern-template-record-source-or stale-session stale-template -1)
            -1
            "stale template handle fails closed")
          (test.assert-false
            (= stale-template next-template)
            "reset re-owners newly canonicalized records"))))))

(test
  compiler-intern-fresh-local-growth-beyond-pool-capacity
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "growth-name")]
    [session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    [_template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity session source)]
    [limit : i64 131073]
    [index : i64 0]
    [last : i64 -1]
    (begin
      (while (< index limit)
        (begin
          (set!
            last
            (cis.intern-fresh-local-identity-raw
              (cis.intern-structural-session-fresh-local-identity
                session
                index
                source)))
          (set! index (+ index 1))))
      (test.assert-true
        (intern-fresh-record-components-match? session last (- limit 1) source)
        "the record after the old 131072 pool limit round-trips")
      (test.assert-i64-eq
        (cis.intern-structural-session-kind-count
          session
          (ci.intern-structural-kind-fresh-local))
        limit
        "fresh-local kind count includes every growth insertion")
      (test.assert-i64-eq
        (cis.intern-structural-session-kind-count
          session
          (ci.intern-structural-kind-template-source))
        1
        "template-source kind count remains independent")
      (test.assert-i64-eq
        (cis.intern-structural-session-record-count session)
        (+ limit 1)
        "structural record count is independent of source-name capacity")
      (test.assert-true
        (>= (cis.intern-structural-session-record-capacity session) limit)
        "record columns grow to retain collision-probed insertions")
      (test.assert-i64-eq
        (ci.intern-structural-record-slot-bytes)
        37
        "each reserved structural record slot uses 37 payload bytes")
      (test.assert-true
        (>=
          (cis.intern-structural-session-record-reserved-bytes session)
          (* limit (ci.intern-structural-record-slot-bytes)))
        "reserved-byte metric covers all retained records"))))