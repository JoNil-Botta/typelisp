;# Allocation-free scalar data for TypeLisp's reviewed Unicode 12.0.0 IDNA
;# protocol profile. This module performs no decoding or label validation.
;# IANA's derived-property snapshot is convenience data; its contextual rules
;# are normative updates to RFC 5892. See tools/idna-unicode12-data/README.md.
(import stdlib.generated.idna_unicode12_data as data)
(import stdlib.string)

(defenum DerivedProperty
  (Disallowed)
  (PValid)
  (ContextJ)
  (ContextO)
  (Unassigned))

(defenum ContextScript
  (OtherScript)
  (Greek)
  (Hebrew)
  (Hiragana)
  (Katakana)
  (Han))

(defenum JoiningType
  (NonJoining)
  (LeftJoining)
  (DualJoining)
  (Transparent)
  (RightJoining)
  (JoinCausing))

(defenum BidiClass
  (L)
  (R)
  (AL)
  (EN)
  (ES)
  (ET)
  (AN)
  (CS)
  (NSM)
  (BN)
  (B)
  (S)
  (WS)
  (ON)
  (LRE)
  (LRO)
  (RLE)
  (RLO)
  (PDF)
  (LRI)
  (RLI)
  (FSI)
  (PDI))

(defenum NfcQuickCheck
  (NfcYes)
  (NfcNo)
  (NfcMaybe))

(defenum ContextRule
  (NoContextRule)
  (ZeroWidthNonJoiner)
  (ZeroWidthJoiner)
  (MiddleDot)
  (GreekLowerNumeralSign)
  (HebrewGeresh)
  (HebrewGershayim)
  (KatakanaMiddleDot)
  (ArabicIndicDigits)
  (ExtendedArabicIndicDigits))

(defstruct ContextApplicability
  (rule ContextRule)
  (registration bool)
  (lookup bool))

(defstruct ScalarProperties
  (derived DerivedProperty)
  (ccc u8)
  (mark bool)
  (script ContextScript)
  (joining JoiningType)
  (bidi BidiClass)
  (nfc NfcQuickCheck))

(defenum ScalarLookup
  (InvalidScalar)
  (Scalar ScalarProperties))

(defstruct DecompositionSpan
  (valid bool)
  (offset u32)
  (count u8))

;: Reject non-scalars before consulting any table.
(define (valid-scalar? [cp : i64]) : bool
  (and (>= cp 0) (<= cp 1114111) (or (< cp 55296) (> cp 57343))))

;; Internal reads have statically generated widths and checked table indexes.
(define (word [table : (& table str)] [offset : i64] [width : i64]) : u32
  (let
    [value : u32 0]
    [index : i64 0]
    (while (< index width)
      (let
        [c : i64 (cast (string.string-ref table (+ offset index)) : i64)]
        (set!
          value
          (bit-or
            (shl value (cast 4 : u64))
            (cast
              (if (<= c 57)
                (- c 48)
                (- c 55))
              : u32))))
      (set! index (+ index 1)))
    value))

;; Upper-bound search over disjoint ranges covering the entire code-point space.
(define (range-value [table : (& table str)] [width : i64] [cp : i64]) : u32
  (let
    [low : i64 0]
    [high : i64 (/ (string.string-length table) width)]
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        (if (<= (cast (word table (* middle width) 6) : i64) cp)
          (set! low (+ middle 1))
          (set! high middle))))
    (if (or
      (= low 0)
      (> cp (cast (word table (+ (* (- low 1) width) 6) 6) : i64)))
      0
      (word table (+ (* (- low 1) width) 12) (- width 12)))))

;: A closed five-way property. Invalid scalar inputs are Disallowed.
(define (derived-property [cp : i64]) : DerivedProperty
  (match (if (valid-scalar? cp)
    (range-value (data.idna-ranges) 14 cp)
    0)
    [1 (PValid)]
    [2 (ContextJ)]
    [3 (ContextO)]
    [4 (Unassigned)]
    [_ (Disallowed)]))

;: One bounded lookup returns the supporting properties or explicit invalidity.
(define (lookup [cp : i64]) : ScalarLookup
  (if (not (valid-scalar? cp))
    (InvalidScalar)
    (let
      [bits : u32 (range-value (data.support-ranges) 20 cp)]
      (Scalar
        (ScalarProperties
          (derived-property cp)
          (cast (bit-and bits 255) : u8)
          (!= (bit-and bits 256) 0)
          (match (bit-and (shr bits (cast 9 : u64)) 7)
            [1 (Greek)]
            [2 (Hebrew)]
            [3 (Hiragana)]
            [4 (Katakana)]
            [5 (Han)]
            [_ (OtherScript)])
          (match (bit-and (shr bits (cast 12 : u64)) 7)
            [1 (LeftJoining)]
            [2 (DualJoining)]
            [3 (Transparent)]
            [4 (RightJoining)]
            [5 (JoinCausing)]
            [_ (NonJoining)])
          (match (bit-and (shr bits (cast 15 : u64)) 31)
            [1 (R)]
            [2 (AL)]
            [3 (EN)]
            [4 (ES)]
            [5 (ET)]
            [6 (AN)]
            [7 (CS)]
            [8 (NSM)]
            [9 (BN)]
            [10 (B)]
            [11 (S)]
            [12 (WS)]
            [13 (ON)]
            [14 (LRE)]
            [15 (LRO)]
            [16 (RLE)]
            [17 (RLO)]
            [18 (PDF)]
            [19 (LRI)]
            [20 (RLI)]
            [21 (FSI)]
            [22 (PDI)]
            [_ (L)])
          (match (bit-and (shr bits (cast 20 : u64)) 3)
            [1 (NfcNo)]
            [2 (NfcMaybe)]
            [_ (NfcYes)]))))))

;: Closed context identity and applicability; rule evaluation belongs to #7269.
(define (context [cp : i64]) : ContextApplicability
  (let
    [bits : u32
      (if (valid-scalar? cp)
        (range-value (data.context-ranges) 16 cp)
        0)]
    (ContextApplicability
      (match (shr bits (cast 8 : u64))
        [1 (ZeroWidthNonJoiner)]
        [2 (ZeroWidthJoiner)]
        [3 (MiddleDot)]
        [4 (GreekLowerNumeralSign)]
        [5 (HebrewGeresh)]
        [6 (HebrewGershayim)]
        [7 (KatakanaMiddleDot)]
        [8 (ArabicIndicDigits)]
        [9 (ExtendedArabicIndicDigits)]
        [_ (NoContextRule)])
      (!= (bit-and bits 1) 0)
      (!= (bit-and bits 2) 0))))

;: Direct canonical decomposition span. Hangul uses the constants below.
;: An absent decomposition has valid=true and count=0; invalid scalars fail closed.
(define (decomposition [cp : i64]) : DecompositionSpan
  (if (not (valid-scalar? cp))
    (DecompositionSpan false 0 0)
    (let
      [table : String (data.decomposition-index)]
      [low : i64 0]
      [high : i64 (data.decomposition-count)]
      (while (< low high)
        (let
          [middle : i64 (+ low (/ (- high low) 2))]
          (if (< (cast (word table (* middle 16) 6) : i64) cp)
            (set! low (+ middle 1))
            (set! high middle))))
      (if (and
        (< low (data.decomposition-count))
        (= (cast (word table (* low 16) 6) : i64) cp))
        (DecompositionSpan
          true
          (word table (+ (* low 16) 6) 8)
          (cast (word table (+ (* low 16) 14) 2) : u8))
        (DecompositionSpan true 0 0)))))

;: Read within a checked span. Returns -1 for forged spans or invalid indexes.
(define (decomposition-at [span : DecompositionSpan] [index : i64]) : i64
  (let
    [offset : i64 (cast span.offset : i64)]
    [count : i64 (cast span.count : i64)]
    (if (or
      (not span.valid)
      (< index 0)
      (>= index count)
      (> (+ offset count) (data.pool-count)))
      -1
      (cast (word (data.decomposition-pool) (* (+ offset index) 6) 6) : i64))))

;: Canonical non-Hangul composition, excluding Full_Composition_Exclusion.
;: Returns -1 when no pair exists or either operand is invalid.
(define (composition [first : i64] [second : i64]) : i64
  (if (or (not (valid-scalar? first)) (not (valid-scalar? second)))
    -1
    (let
      [table : String (data.composition-pairs)]
      [low : i64 0]
      [high : i64 (data.composition-count)]
      [key : i64 (+ (* first 2097152) second)]
      (while (< low high)
        (let
          [middle : i64 (+ low (/ (- high low) 2))]
          [candidate : i64
            (+
              (* (cast (word table (* middle 18) 6) : i64) 2097152)
              (cast (word table (+ (* middle 18) 6) 6) : i64))]
          (if (< candidate key)
            (set! low (+ middle 1))
            (set! high middle))))
      (if (and
        (< low (data.composition-count))
        (= (cast (word table (* low 18) 6) : i64) first)
        (= (cast (word table (+ (* low 18) 6) 6) : i64) second))
        (cast (word table (+ (* low 18) 12) 6) : i64)
        -1))))

;: Unicode 12 algorithmic Hangul constants (Unicode Standard section 3.12).
(define (hangul-s-base) : i64
  44032)

(define (hangul-l-base) : i64
  4352)

(define (hangul-v-base) : i64
  4449)

(define (hangul-t-base) : i64
  4519)

(define (hangul-l-count) : i64
  19)

(define (hangul-v-count) : i64
  21)

(define (hangul-t-count) : i64
  28)

(define (hangul-n-count) : i64
  588)

(define (hangul-s-count) : i64
  11172)