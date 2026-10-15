(import stdlib.idna_unicode12 as idna)
(import stdlib.test)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)

(define (boundaries) : unit
  (match (idna.lookup 55296)
    [(idna.InvalidScalar) unit]
    [_ (test.assert-true false "surrogates fail closed")])
  (match (idna.derived-property 97)
    [(idna.PValid) unit]
    [_ (test.assert-true false "ASCII lowercase is PVALID")])
  (match (idna.derived-property 65)
    [(idna.Disallowed) unit]
    [_ (test.assert-true false "ASCII uppercase is DISALLOWED")])
  (test.assert-i64-eq (idna.composition 65 778) 197 "canonical composition")
  (test.assert-i64-eq (idna.composition 776 769) -1 "composition exclusion")
  (test.assert-i64-eq
    (idna.decomposition-at (idna.decomposition 8491) 0)
    197
    "canonical singleton")
  (test.assert-i64-eq
    (idna.decomposition-at (idna.decomposition 119134) 1)
    119141
    "supplementary decomposition")
  (test.assert-i64-eq
    (idna.decomposition-at (idna.DecompositionSpan true 4294967295 2) 0)
    -1
    "forged span fails closed"))

(define (context-support) : unit
  (match (idna.lookup 2381)
    [(idna.Scalar props)
      (test.assert-i64-eq (cast props.ccc : i64) 9 "Virama CCC")
      (test.assert-true props.mark "Virama is a Mark")]
    [_ (test.assert-true false "Virama scalar lookup")])
  (match (idna.lookup 1424)
    [(idna.Scalar props)
      (match props.bidi
        [(idna.R) unit]
        [_ (test.assert-true false "unassigned bidi R default")])]
    [_ (test.assert-true false "unassigned scalar lookup")])
  (let
    [joiner : idna.ContextApplicability (idna.context 8204)]
    [middle : idna.ContextApplicability (idna.context 183)]
    (test.assert-true
      (and joiner.registration joiner.lookup)
      "CONTEXTJ applicability")
    (test.assert-true
      (and middle.registration (not middle.lookup))
      "CONTEXTO applicability")
    (match joiner.rule
      [(idna.ZeroWidthNonJoiner) unit]
      [_ (test.assert-true false "closed rule identity")])))

(test idna-unicode12-scalar-boundaries (boundaries))

(test idna-unicode12-context-support (context-support))

(define (main) : i64
  (let
    [argument : String (io.arg 0)]
    (test.assert-true (> (string.string-length argument) 0) "allocation probe")
    (test.assert-true
      (> (profile.alloc-total) 0)
      "allocation counters are active"))
  (let
    [before : i64 (profile.alloc-total)]
    (boundaries)
    (context-support)
    (test.assert-i64-eq
      (profile.alloc-total)
      before
      "scalar APIs allocate nothing"))
  (io.println "lookup allocated bytes=0")
  42)