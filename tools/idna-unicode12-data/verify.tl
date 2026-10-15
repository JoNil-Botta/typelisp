(import parse)
(import pins)
(import read)
(import normalization as norm)
(import stdlib.idna_unicode12 as idna)
(import stdlib.generated.idna_unicode12_data as tables)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)

(define (derived-code [value : idna.DerivedProperty]) : u8
  (match value
    [(idna.Disallowed) 0]
    [(idna.PValid) 1]
    [(idna.ContextJ) 2]
    [(idna.ContextO) 3]
    [(idna.Unassigned) 4]))

(define (script-code [value : idna.ContextScript]) : u32
  (match value
    [(idna.OtherScript) 0]
    [(idna.Greek) 1]
    [(idna.Hebrew) 2]
    [(idna.Hiragana) 3]
    [(idna.Katakana) 4]
    [(idna.Han) 5]))

(define (joining-code [value : idna.JoiningType]) : u32
  (match value
    [(idna.NonJoining) 0]
    [(idna.LeftJoining) 1]
    [(idna.DualJoining) 2]
    [(idna.Transparent) 3]
    [(idna.RightJoining) 4]
    [(idna.JoinCausing) 5]))

(define (bidi-code [value : idna.BidiClass]) : u32
  (match value
    [(idna.L) 0]
    [(idna.R) 1]
    [(idna.AL) 2]
    [(idna.EN) 3]
    [(idna.ES) 4]
    [(idna.ET) 5]
    [(idna.AN) 6]
    [(idna.CS) 7]
    [(idna.NSM) 8]
    [(idna.BN) 9]
    [(idna.B) 10]
    [(idna.S) 11]
    [(idna.WS) 12]
    [(idna.ON) 13]
    [(idna.LRE) 14]
    [(idna.LRO) 15]
    [(idna.RLE) 16]
    [(idna.RLO) 17]
    [(idna.PDF) 18]
    [(idna.LRI) 19]
    [(idna.RLI) 20]
    [(idna.FSI) 21]
    [(idna.PDI) 22]))

(define (quick-code [value : idna.NfcQuickCheck]) : u32
  (match value
    [(idna.NfcYes) 0]
    [(idna.NfcNo) 1]
    [(idna.NfcMaybe) 2]))

(define (context-code [value : idna.ContextRule]) : i64
  (match value
    [(idna.NoContextRule) 0]
    [(idna.ZeroWidthNonJoiner) 1]
    [(idna.ZeroWidthJoiner) 2]
    [(idna.MiddleDot) 3]
    [(idna.GreekLowerNumeralSign) 4]
    [(idna.HebrewGeresh) 5]
    [(idna.HebrewGershayim) 6]
    [(idna.KatakanaMiddleDot) 7]
    [(idna.ArabicIndicDigits) 8]
    [(idna.ExtendedArabicIndicDigits) 9]))

(define (invalid [cp : i64]) : unit
  (match (idna.lookup cp)
    [(idna.InvalidScalar) unit]
    [(idna.Scalar _) (parse.fail "lookup" cp "accepted invalid scalar")])
  (when
    (or
      (!= (derived-code (idna.derived-property cp)) 0)
      (idna.decomposition cp).valid
      (!= (idna.composition cp 65) -1)
      (!= (idna.composition 65 cp) -1)
      (!= (context-code (idna.context cp).rule) 0)
      (idna.context cp).registration
      (idna.context cp).lookup)
    (parse.fail "lookup" cp "invalid scalar did not fail closed")))

(define (support-fixtures) : unit
  (let
    [script-cps : (Array i64 6) (array 97 945 1488 12354 12450 19968)]
    [joining-cps : (Array i64 6) (array 97 43122 1568 173 1570 1600)]
    [bidi-cps : (Array i64 23)
      (array
        65
        1424
        1544
        48
        43
        35
        1536
        44
        768
        0
        10
        9
        12
        33
        8234
        8237
        8235
        8238
        8236
        8294
        8295
        8296
        8297)]
    [context-cps : (Array i64 9)
      (array 8204 8205 183 885 1523 1524 12539 1632 1776)]
    [mark-cps : (Array i64 3) (array 769 2307 1160)]
    [index : i64 0]
    (while (< index 23)
      (match (idna.lookup (array-ref bidi-cps index))
        [(idna.Scalar props)
          (when
            (!= (cast (bidi-code props.bidi) : i64) index)
            (parse.fail "bidi fixture" index "wrong closed bidi class"))]
        [_ (parse.fail "bidi fixture" index "invalid scalar")])
      (when
        (< index 6)
        (match (idna.lookup (array-ref script-cps index))
          [(idna.Scalar props)
            (when
              (!= (cast (script-code props.script) : i64) index)
              (parse.fail
                "script fixture"
                index
                "wrong closed contextual script"))]
          [_ (parse.fail "script fixture" index "invalid scalar")])
        (match (idna.lookup (array-ref joining-cps index))
          [(idna.Scalar props)
            (when
              (!= (cast (joining-code props.joining) : i64) index)
              (parse.fail "joining fixture" index "wrong closed joining type"))]
          [_ (parse.fail "joining fixture" index "invalid scalar")]))
      (when
        (< index 9)
        (when
          (!=
            (context-code (idna.context (array-ref context-cps index)).rule)
            (+ index 1))
          (parse.fail "context fixture" index "wrong closed rule identity")))
      (when
        (< index 3)
        (match (idna.lookup (array-ref mark-cps index))
          [(idna.Scalar props)
            (when
              (not props.mark)
              (parse.fail "Mark fixture" index "Mn/Mc/Me must all be Marks"))]
          [_ (parse.fail "Mark fixture" index "invalid scalar")]))
      (set! index (+ index 1)))))

(define (smoke) : unit
  (invalid -1)
  (invalid -9223372036854775808)
  (invalid 1114112)
  (invalid 9223372036854775807)
  (let
    [cp : i64 55296]
    (while (<= cp 57343)
      (invalid cp)
      (set! cp (+ cp 1))))
  (when
    (or
      (not (string.eq (tables.schema) (pins.schema)))
      (not (string.eq (tables.unicode-version) "12.0.0"))
      (!= (idna.composition 65 778) 197)
      (!= (idna.composition 776 769) -1)
      (!= (idna.decomposition-at (idna.decomposition 8491) 0) 197)
      (!=
        (idna.decomposition-at (idna.DecompositionSpan true 4294967295 2) 0)
        -1)
      (!= (idna.decomposition-at (idna.decomposition 197) -1) -1)
      (!= (idna.decomposition-at (idna.decomposition 197) 2) -1))
    (parse.fail "lookup" 0 "schema, composition or checked-span failure"))
  (support-fixtures)
  (norm.hangul))

(define (exhaustive [data : (& data read.Data)]) : unit
  (let
    [cp : i64 0]
    [context-total : i64 0]
    [lookup-total : i64 0]
    [rules : (Array bool 10) (make-array bool 10)]
    [bidi : (Array bool 23) (make-array bool 23)]
    [joining : (Array bool 6) (make-array bool 6)]
    [scripts : (Array bool 6) (make-array bool 6)]
    [alloc-before : i64 (profile.alloc-total)]
    (while (< cp 1114112)
      (when
        (idna.valid-scalar? cp)
        (match (idna.lookup cp)
          [(idna.InvalidScalar)
            (parse.fail "lookup" cp "rejected valid scalar")]
          [(idna.Scalar props)
            (let
              [bits : u32
                (bit-or
                  (cast props.ccc : u32)
                  (if props.mark
                    256
                    0)
                  (shl (script-code props.script) (cast 9 : u64))
                  (shl (joining-code props.joining) (cast 12 : u64))
                  (shl (bidi-code props.bidi) (cast 15 : u64))
                  (shl (quick-code props.nfc) (cast 20 : u64)))]
              (when
                (or
                  (!= bits (bit-and (array-ref data.facts cp) 0x3fffff))
                  (!= (derived-code props.derived) (array-ref data.idna cp)))
                (parse.fail
                  "lookup"
                  cp
                  "support or derived property differs from pinned source"))
              (set! (array-ref bidi (cast (bidi-code props.bidi) : i64)) true)
              (set!
                (array-ref joining (cast (joining-code props.joining) : i64))
                true)
              (set!
                (array-ref scripts (cast (script-code props.script) : i64))
                true))])
        (let
          [span : idna.DecompositionSpan (idna.decomposition cp)]
          [index : i64 0]
          [offset : i64 (cast (array-ref data.offsets cp) : i64)]
          [context : idna.ContextApplicability (idna.context cp)]
          (when
            (or (not span.valid) (!= span.count (array-ref data.lengths cp)))
            (parse.fail "decomposition" cp "span differs from UnicodeData"))
          (while (< index (cast span.count : i64))
            (when
              (!=
                (idna.decomposition-at span index)
                (cast (array-ref data.pool (+ offset index)) : i64))
              (parse.fail "decomposition" cp "pool differs from UnicodeData"))
            (set! index (+ index 1)))
          (when
            (= span.count 2)
            (let
              [composed : i64
                (idna.composition
                  (idna.decomposition-at span 0)
                  (idna.decomposition-at span 1))]
              [excluded : bool (!= (bit-and (array-ref data.seen cp) 16) 0)]
              (when
                (if excluded
                  (= composed cp)
                  (!= composed cp))
                (parse.fail
                  "composition"
                  cp
                  "exclusion or pair differs from pinned source"))))
          (set! (array-ref rules (context-code context.rule)) true)
          (when context.registration (set! context-total (+ context-total 1)))
          (when context.lookup (set! lookup-total (+ lookup-total 1)))
          (when
            (!=
              context.registration
              (or (= (array-ref data.idna cp) 2) (= (array-ref data.idna cp) 3)))
            (parse.fail
              "context"
              cp
              "registry coverage differs from derived property"))))
      (set! cp (+ cp 1)))
    (when
      (!= (profile.alloc-total) alloc-before)
      (parse.fail "lookup" 0 "scalar lookup allocated"))
    (when
      (or (!= context-total 27) (!= lookup-total 2))
      (parse.fail "context" 0 "context applicability counts changed"))
    (set! cp 0)
    (while (< cp 23)
      (when
        (or
          (not (array-ref bidi cp))
          (and
            (< cp 6)
            (or (not (array-ref joining cp)) (not (array-ref scripts cp))))
          (and (< cp 10) (not (array-ref rules cp))))
        (parse.fail "lookup" cp "closed property fixture coverage missing"))
      (set! cp (+ cp 1)))
    (io.println
      "exhaustive: 1112064 scalars; 2048 surrogates rejected; 27 contextual scalars; lookup allocated bytes=0")))

(define (main) : i64
  (if (!= (io.arg-count) 2)
    (begin
      (io.eprintln "usage: verify <pinned-input-directory>")
      2)
    (let
      [texts : (__tl_dyn-array String) (read.sources (io.arg 1))]
      [data : read.Data (read.new)]
      (read.idna (&mut data) (& (array-ref texts 1)))
      (read.unicode-data (&mut data) (& (array-ref texts 2)))
      (read.normalization (&mut data) (& (array-ref texts 3)))
      (read.properties (&mut data) (& (array-ref texts 5)) 5)
      (read.properties (&mut data) (& (array-ref texts 6)) 6)
      (read.properties (&mut data) (& (array-ref texts 7)) 7)
      (when
        (<= (profile.alloc-total) 0)
        (parse.fail "lookup" 0 "allocation counters are inactive"))
      (smoke)
      (exhaustive (& data))
      (io.println
        "NFC/NFD vectors={} Hangul syllables=11172 plus both boundaries"
        (norm.vectors (& (array-ref texts 4))))
      0)))