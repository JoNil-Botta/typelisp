;# Bounded public-input RSA integer and Montgomery arithmetic.
;#
;# This module is an internal cryptographic building block. It accepts only
;# public RSA moduli, exponents, and representatives; it is not a general
;# multiprecision package and must never receive a private factor, private
;# exponent, CRT value, blinding value, or other secret-dependent operand.
;#
;# Unsigned integers cross the boundary as canonical big-endian bytes. Signed
;# container decoders use `parse-public-key-signed` after removing their one
;# permitted positive sign octet. The core preserves the modulus octet width
;# required by RFC 8017 OS2IP/I2OSP.
;#
;# Storage is selected from public 2048-, 3072-, 4096-, and 8192-bit capacity
;# classes and uses base-2^32 limbs. Public exponents are limited to canonical
;# odd unsigned 32-bit values in [3, 2^32-1]. Public exponentiation is variable
;# work and makes no constant-time claim.
;#
;# Usage: internal RSA verification/import modules only.
(import stdlib.byte_buf)
(cfg test (import stdlib.test))

;: Stable public-input validation and arithmetic failure categories.
(defenum RsaCoreErrorKind
  (RsaNegativeModulus)
  (RsaNegativeExponent)
  (RsaInvalidModulusLength)
  (RsaNonCanonicalModulus)
  (RsaModulusTooSmall)
  (RsaModulusTooLarge)
  (RsaEvenModulus)
  (RsaInvalidExponentLength)
  (RsaNonCanonicalExponent)
  (RsaExponentTooSmall)
  (RsaExponentTooLarge)
  (RsaEvenExponent)
  (RsaInvalidRepresentativeLength)
  (RsaRepresentativeOutOfRange)
  (RsaArithmeticInvariant))

;: Bounded error detail. `offset` is an input offset, length, or public bound.
(defstruct RsaCoreError
  (kind RsaCoreErrorKind)
  (offset i64))

;: Fixed-capacity-class public magnitude. Every stored u32 is one base-2^32
;: little-endian limb; `limb-count` is normalized and `capacity` is one of the
;: four admitted public classes.
(defstruct RsaPublicInteger
  (limbs (__tl_dyn-array u32))
  (limb-count i64)
  (capacity i64)
  (octet-width i64))

;: Checked public RSA key plus Montgomery parameters for its odd modulus.
(defstruct RsaPublicKey
  (modulus RsaPublicInteger)
  (r-squared RsaPublicInteger)
  (exponent u64)
  (modulus-bits i64)
  (class-bits i64)
  (n0-inverse u64))

;: Result of parsing and preparing one checked public key.
(defenum ResultRsaPublicKey
  (OkRsaPublicKey RsaPublicKey)
  (ErrRsaPublicKey RsaCoreError))

;: Result of exact-width public modular exponentiation.
(defenum ResultRsaPublicBytes
  (OkRsaPublicBytes byte_buf.ByteBuf)
  (ErrRsaPublicBytes RsaCoreError))

;: Allocation-free result of checking a public key input pair. Success carries
;: exact modulus bits, selected limb capacity, and the decoded exponent.
(defenum RsaPublicKeyInputValidation
  (RsaPublicKeyInputValid i64 i64 u64)
  (RsaPublicKeyInputInvalid RsaCoreError))

;: Smallest admitted RSA modulus bit length.
(define rsa-minimum-modulus-bits : i64
  2048)

;: Largest admitted RSA modulus bit length and storage class.
(define rsa-maximum-modulus-bits : i64
  8192)

;: Largest admitted canonical modulus byte string.
(define rsa-maximum-modulus-bytes : i64
  1024)

;: Largest admitted public exponent, 2^32-1.
(define rsa-maximum-public-exponent : u64
  4294967295)

;: Base-2^32 low-limb mask.
(define rsa-limb-mask : u64
  0xffffffff)

;: Numeric radix represented by one limb.
(define rsa-limb-radix : u64
  4294967296)

;: Construct a stable error.
(define (rsa-error [kind : RsaCoreErrorKind] [offset : i64]) : RsaCoreError
  (RsaCoreError kind offset))

;: Return the checked modulus byte width retained by a public key.
(define (modulus-octet-width [key : (& key RsaPublicKey)]) : i64
  key.modulus.octet-width)

;: Return the exact checked modulus bit length.
(define (modulus-bit-length [key : (& key RsaPublicKey)]) : i64
  key.modulus-bits)

;: Return the selected public storage class in bits.
(define (modulus-class-bits [key : (& key RsaPublicKey)]) : i64
  key.class-bits)

;: Return the checked public exponent.
(define (public-exponent [key : (& key RsaPublicKey)]) : u64
  key.exponent)

;: Select the smallest documented capacity class for `bits`, or zero.
(define (class-limbs-for-bits [bits : i64]) : i64
  (cond
    [(or (< bits rsa-minimum-modulus-bits) (> bits rsa-maximum-modulus-bits)) 0]
    [(<= bits 2048) 64]
    [(<= bits 3072) 96]
    [(<= bits 4096) 128]
    [else 256]))

;: Convert one capacity to its public class width in bits, or zero.
(define (class-bits-for-limbs [limbs : i64]) : i64
  (cond
    [(= limbs 64) 2048]
    [(= limbs 96) 3072]
    [(= limbs 128) 4096]
    [(= limbs 256) 8192]
    [else 0]))

;: Bit length of one nonzero byte.
(define (nonzero-byte-bit-length [byte : u8]) : i64
  (let
    [value : u64 (cast byte : u64)]
    [bits : i64 0]
    (begin
      (while (> value (cast 0 : u64))
        (begin
          (set! bits (+ bits 1))
          (set! value (shr value 1))))
      bits)))

;: Exact bit length of a canonical nonempty big-endian magnitude.
(define (canonical-byte-bit-length [bytes : (& bytes bytes)]) : i64
  (+
    (* (- (byte_buf.bytes-length bytes) 1) 8)
    (nonzero-byte-bit-length (byte_buf.bytes-ref bytes 0))))

;: Parse at most four canonical exponent bytes into u64.
(define (parse-exponent-value [bytes : (& bytes bytes)]) : u64
  (let
    [value : u64 (cast 0 : u64)]
    [index : i64 0]
    [length : i64 (byte_buf.bytes-length bytes)]
    (begin
      (while (< index length)
        (begin
          (set!
            value
            (bit-or (shl value 8) (cast (byte_buf.bytes-ref bytes index) : u64)))
          (set! index (+ index 1))))
      value)))

;: Allocate a zero public integer in an already validated capacity class.
(define (zero-integer [capacity : i64] [octet-width : i64]) : RsaPublicInteger
  (RsaPublicInteger (__tl_make-array u32 capacity) 0 capacity octet-width))

;: Normalize at most `limit` little-endian limbs.
(define (normalized-limb-count
  [limbs : (& limbs (__tl_dyn-array u32))]
  [limit : i64]) : i64
  (let
    [count : i64 limit]
    (begin
      (while (and (> count 0) (= (array-ref limbs (- count 1)) (cast 0 : u32)))
        (set! count (- count 1)))
      count)))

;: Decode a bounded big-endian magnitude into base-2^32 little-endian limbs.
(define (integer-from-bytes-in-class
  [bytes : (& bytes bytes)]
  [capacity : i64]
  [octet-width : i64]) : RsaPublicInteger
  (let
    [out : RsaPublicInteger (zero-integer capacity octet-width)]
    [length : i64 (byte_buf.bytes-length bytes)]
    [from-end : i64 0]
    (begin
      (while (< from-end length)
        (let
          [limb-index : i64 (/ from-end 4)]
          [shift : i64 (* (% from-end 4) 8)]
          [source-index : i64 (- (- length 1) from-end)]
          [part : u64
            (shl (cast (byte_buf.bytes-ref bytes source-index) : u64) shift)]
          [current : u64 (cast (array-ref out.limbs limb-index) : u64)]
          (begin
            (set!
              (array-ref out.limbs limb-index)
              (cast (bit-or current part) : u32))
            (set! from-end (+ from-end 1)))))
      (set!
        out.limb-count
        (normalized-limb-count (& out.limbs) (/ (+ length 3) 4)))
      out)))

;: Return a same-class integer containing one.
(define (one-like [value : (& value RsaPublicInteger)]) : RsaPublicInteger
  (let
    [out : RsaPublicInteger (zero-integer value.capacity value.octet-width)]
    (begin
      (set! (array-ref out.limbs 0) (cast 1 : u32))
      (set! out.limb-count 1)
      out)))

;: Compare exactly `count` low limbs, returning -1, 0, or 1.
(define (compare-limbs
  [left : (& left (__tl_dyn-array u32))]
  [right : (& right (__tl_dyn-array u32))]
  [count : i64]) : i64
  (let
    [index : i64 (- count 1)]
    [result : i64 0]
    [done : bool false]
    (begin
      (while (and (>= index 0) (not done))
        (let
          [a : u32 (array-ref left index)]
          [b : u32 (array-ref right index)]
          (begin
            (cond
              [(> a b)
                (begin
                  (set! result 1)
                  (set! done true))]
              [(< a b)
                (begin
                  (set! result -1)
                  (set! done true))]
              [else unit])
            (set! index (- index 1)))))
      result)))

;: Subtract `modulus` once from the low limbs of `value`. The caller proves
;: that its optional implicit top limb and the final borrow cancel exactly:
;: both doubling and REDC enter only for a value in [n, 2n), so dropping that
;: consumed implicit limb is not carry truncation.
(define (subtract-modulus-once!
  [value : (&mut value RsaPublicInteger)]
  [modulus : (& modulus RsaPublicInteger)]
  [count : i64]) : unit
  (let
    [borrow : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [a : u64 (cast (array-ref value.limbs index) : u64)]
          [subtrahend : u64
            (+ (cast (array-ref modulus.limbs index) : u64) borrow)]
          [underflow : bool (< a subtrahend)]
          [difference : u64
            (if underflow
              (- (+ rsa-limb-radix a) subtrahend)
              (- a subtrahend))]
          (begin
            (set! (array-ref value.limbs index) (cast difference : u32))
            (set!
              borrow
              (if underflow
                (cast 1 : u64)
                (cast 0 : u64)))
            (set! index (+ index 1)))))
      unit)))

;: Double one value below `modulus` and reduce it with at most one subtraction.
(define (double-modulus!
  [value : (&mut value RsaPublicInteger)]
  [modulus : (& modulus RsaPublicInteger)]) : unit
  (let
    [count : i64 modulus.limb-count]
    [carry : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [twice : u64
            (+ (* (cast (array-ref value.limbs index) : u64) 2) carry)]
          (begin
            (set!
              (array-ref value.limbs index)
              (cast (bit-and twice rsa-limb-mask) : u32))
            (set! carry (shr twice 32))
            (set! index (+ index 1)))))
      (if (or
        (> carry (cast 0 : u64))
        (>= (compare-limbs (& value.limbs) (& modulus.limbs) count) 0))
        (subtract-modulus-once! value modulus count)
        unit)
      (set! value.limb-count (normalized-limb-count (& value.limbs) count))
      unit)))

;: Add two checked values below `modulus` and reduce the first in place. The
;: n-limb sum is below 2n, so its explicit carry is consumed by at most one
;: modulus subtraction.
(define (add-modulus!
  [left : (&mut left RsaPublicInteger)]
  [right : (& right RsaPublicInteger)]
  [modulus : (& modulus RsaPublicInteger)]) : unit
  (let
    [count : i64 modulus.limb-count]
    [carry : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [sum : u64
            (+
              (+
                (cast (array-ref left.limbs index) : u64)
                (cast (array-ref right.limbs index) : u64))
              carry)]
          (begin
            (set!
              (array-ref left.limbs index)
              (cast (bit-and sum rsa-limb-mask) : u32))
            (set! carry (shr sum 32))
            (set! index (+ index 1)))))
      (if (or
        (> carry (cast 0 : u64))
        (>= (compare-limbs (& left.limbs) (& modulus.limbs) count) 0))
        (subtract-modulus-once! left modulus count)
        unit)
      (set! left.limb-count (normalized-limb-count (& left.limbs) count))
      unit)))

;: Compute -n[0]^-1 modulo 2^32 for one odd low limb.
(define (montgomery-n0-inverse [low-limb : u32]) : u64
  (let
    [n : u64 (cast low-limb : u64)]
    [inverse : u64 (cast 1 : u64)]
    [round : i64 0]
    (begin
      ;; Each Newton round doubles the number of correct low bits.
      (while (< round 5)
        (let
          [product-low : u64 (bit-and (* n inverse) rsa-limb-mask)]
          [factor : u64 (bit-and (- (cast 2 : u64) product-low) rsa-limb-mask)]
          (begin
            (set! inverse (bit-and (* inverse factor) rsa-limb-mask))
            (set! round (+ round 1)))))
      (bit-and (- rsa-limb-radix inverse) rsa-limb-mask))))

;: Compute R^2 mod n by 64*n checked modular doublings.
(define (montgomery-r-squared [modulus : (& modulus RsaPublicInteger)]) : RsaPublicInteger
  (let
    [value : RsaPublicInteger (one-like modulus)]
    [rounds : i64 (* modulus.limb-count 64)]
    [round : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (double-modulus! (&mut value) modulus)
          (set! round (+ round 1))))
      value)))

;: Multiply two n-limb inputs into a zeroed 2n+2-limb u64 scratch. Scratch
;: slots always contain one low 32-bit limb after each committed inner step.
(define (schoolbook-product
  [left : (& left RsaPublicInteger)]
  [right : (& right RsaPublicInteger)]
  [count : i64]) : (__tl_dyn-array u64)
  (let
    [wide : (__tl_dyn-array u64) (__tl_make-array u64 (+ (* count 2) 2))]
    [left-index : i64 0]
    (begin
      (while (< left-index count)
        (let
          [left-limb : u64 (cast (array-ref left.limbs left-index) : u64)]
          [right-index : i64 0]
          [carry : u64 (cast 0 : u64)]
          (begin
            (while (< right-index count)
              (let
                [wide-index : i64 (+ left-index right-index)]
                [sum : u64
                  (+
                    (+
                      (array-ref wide wide-index)
                      (*
                        left-limb
                        (cast (array-ref right.limbs right-index) : u64)))
                    carry)]
                (begin
                  (set! (array-ref wide wide-index) (bit-and sum rsa-limb-mask))
                  (set! carry (shr sum 32))
                  (set! right-index (+ right-index 1)))))
            (set! (array-ref wide (+ left-index count)) carry)
            (set! left-index (+ left-index 1)))))
      wide)))

;: Montgomery product `left * right * R^-1 mod modulus` using classic REDC.
;: All operands are public and below `modulus`.
(define (montgomery-multiply
  [left : (& left RsaPublicInteger)]
  [right : (& right RsaPublicInteger)]
  [modulus : (& modulus RsaPublicInteger)]
  [n0-inverse : u64]) : RsaPublicInteger
  (let
    [count : i64 modulus.limb-count]
    [wide : (__tl_dyn-array u64) (schoolbook-product left right count)]
    [outer : i64 0]
    (begin
      (while (< outer count)
        (let
          [factor : u64
            (bit-and (* (array-ref wide outer) n0-inverse) rsa-limb-mask)]
          [inner : i64 0]
          [carry : u64 (cast 0 : u64)]
          (begin
            (while (< inner count)
              (let
                [index : i64 (+ outer inner)]
                [sum : u64
                  (+
                    (+
                      (array-ref wide index)
                      (* factor (cast (array-ref modulus.limbs inner) : u64)))
                    carry)]
                (begin
                  (set! (array-ref wide index) (bit-and sum rsa-limb-mask))
                  (set! carry (shr sum 32))
                  (set! inner (+ inner 1)))))
            (let
              [carry-index : i64 (+ outer count)]
              (while (> carry (cast 0 : u64))
                (let
                  [sum : u64 (+ (array-ref wide carry-index) carry)]
                  (begin
                    (set!
                      (array-ref wide carry-index)
                      (bit-and sum rsa-limb-mask))
                    (set! carry (shr sum 32))
                    (set! carry-index (+ carry-index 1))))))
            (set! outer (+ outer 1)))))
      (let
        [out : RsaPublicInteger
          (zero-integer modulus.capacity modulus.octet-width)]
        [copy-index : i64 0]
        (begin
          (while (< copy-index count)
            (begin
              (set!
                (array-ref out.limbs copy-index)
                (cast (array-ref wide (+ count copy-index)) : u32))
              (set! copy-index (+ copy-index 1))))
          (let
            [top : u64 (array-ref wide (* count 2))]
            (if (or
              (> top (cast 0 : u64))
              (>= (compare-limbs (& out.limbs) (& modulus.limbs) count) 0))
              (subtract-modulus-once! (&mut out) modulus count)
              unit))
          (set! out.limb-count (normalized-limb-count (& out.limbs) count))
          out)))))

;: Convert a normal representative into the Montgomery domain.
(define (to-montgomery
  [value : (& value RsaPublicInteger)]
  [key : (& key RsaPublicKey)]) : RsaPublicInteger
  (montgomery-multiply value (& key.r-squared) (& key.modulus) key.n0-inverse))

;: Convert a Montgomery-domain representative back to its normal magnitude.
(define (from-montgomery
  [value : (& value RsaPublicInteger)]
  [key : (& key RsaPublicKey)]) : RsaPublicInteger
  (let
    [one : RsaPublicInteger (one-like (& key.modulus))]
    (montgomery-multiply value (& one) (& key.modulus) key.n0-inverse)))

;: Number of significant bits in the checked nonzero public exponent.
(define (exponent-bit-length [exponent : u64]) : i64
  (let
    [value : u64 exponent]
    [bits : i64 0]
    (begin
      (while (> value (cast 0 : u64))
        (begin
          (set! bits (+ bits 1))
          (set! value (shr value 1))))
      bits)))

;: Number of Montgomery multiplications performed by exponentiation,
;: including conversion in/out but excluding key setup.
(define (public-exponentiation-multiplication-count
  [key : (& key RsaPublicKey)]) : i64
  (let
    [bits : i64 (exponent-bit-length key.exponent)]
    [ones : i64 0]
    [index : i64 0]
    (begin
      (while (< index bits)
        (begin
          (if (!=
            (bit-and (shr key.exponent index) (cast 1 : u64))
            (cast 0 : u64))
            (set! ones (+ ones 1))
            unit)
          (set! index (+ index 1))))
      (+ (+ bits ones) 3))))

;: Conservative active-arena bytes retained by one exponentiation. Each
;: Montgomery multiply allocates one result and one 2n+2 u64 scratch. The
;: allocation term includes the runtime's 16-byte dynamic-array headers plus
;: two spare headers so this remains an upper bound as values cross result
;: boundaries.
(define (public-exponentiation-retained-bytes-upper-bound
  [key : (& key RsaPublicKey)]) : i64
  (let
    [multiplications : i64 (public-exponentiation-multiplication-count key)]
    [limbs : i64 key.modulus.limb-count]
    [capacity : i64 key.modulus.capacity]
    [per-multiply : i64 (+ (* capacity 4) (* (+ (* limbs 2) 2) 8))]
    ;; Representative, normal/Montgomery one values, and output backing.
    [fixed : i64 (+ (* capacity 12) key.modulus.octet-width)]
    [allocation-headers : i64 (* (+ (* multiplications 2) 8) 16)]
    (+ (+ fixed allocation-headers) (* multiplications per-multiply))))

;: Validate the complete public key input before any arithmetic allocation.
(define (validate-public-key-input
  [modulus : (& modulus bytes)]
  [modulus-negative : bool]
  [exponent : (& exponent bytes)]
  [exponent-negative : bool]) : RsaPublicKeyInputValidation
  (let
    [modulus-length : i64 (byte_buf.bytes-length modulus)]
    [exponent-length : i64 (byte_buf.bytes-length exponent)]
    (cond
      [modulus-negative
        (RsaPublicKeyInputInvalid (rsa-error (RsaNegativeModulus) 0))]
      [exponent-negative
        (RsaPublicKeyInputInvalid (rsa-error (RsaNegativeExponent) 0))]
      [(<= modulus-length 0)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaInvalidModulusLength) modulus-length))]
      [(> modulus-length rsa-maximum-modulus-bytes)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaModulusTooLarge) modulus-length))]
      [(= (byte_buf.bytes-ref modulus 0) (cast 0 : u8))
        (RsaPublicKeyInputInvalid (rsa-error (RsaNonCanonicalModulus) 0))]
      [(< (canonical-byte-bit-length modulus) rsa-minimum-modulus-bits)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaModulusTooSmall) (canonical-byte-bit-length modulus)))]
      [(> (canonical-byte-bit-length modulus) rsa-maximum-modulus-bits)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaModulusTooLarge) (canonical-byte-bit-length modulus)))]
      [(=
          (bit-and
            (cast (byte_buf.bytes-ref modulus (- modulus-length 1)) : u64)
            (cast 1 : u64))
          (cast 0 : u64))
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaEvenModulus) (- modulus-length 1)))]
      [(<= exponent-length 0)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaInvalidExponentLength) exponent-length))]
      [(> exponent-length 4)
        (RsaPublicKeyInputInvalid
          (rsa-error (RsaExponentTooLarge) exponent-length))]
      [(= (byte_buf.bytes-ref exponent 0) (cast 0 : u8))
        (RsaPublicKeyInputInvalid (rsa-error (RsaNonCanonicalExponent) 0))]
      [else
        (let
          [value : u64 (parse-exponent-value exponent)]
          (cond
            [(< value (cast 3 : u64))
              (RsaPublicKeyInputInvalid (rsa-error (RsaExponentTooSmall) 0))]
            [(> value rsa-maximum-public-exponent)
              (RsaPublicKeyInputInvalid
                (rsa-error (RsaExponentTooLarge) exponent-length))]
            [(= (bit-and value (cast 1 : u64)) (cast 0 : u64))
              (RsaPublicKeyInputInvalid
                (rsa-error (RsaEvenExponent) (- exponent-length 1)))]
            [else
              (let
                [bits : i64 (canonical-byte-bit-length modulus)]
                (RsaPublicKeyInputValid bits (class-limbs-for-bits bits) value))]))])))

;: Parse normalized unsigned magnitudes with explicit signed-container facts.
;: A container decoder must strip only its permitted positive sign octet before
;: this call; setting either negative flag always rejects before allocation.
(define (parse-public-key-signed
  [modulus : (& modulus bytes)]
  [modulus-negative : bool]
  [exponent : (& exponent bytes)]
  [exponent-negative : bool]) : ResultRsaPublicKey
  (match (validate-public-key-input
    modulus
    modulus-negative
    exponent
    exponent-negative)
    [(RsaPublicKeyInputInvalid error) (ErrRsaPublicKey error)]
    [(RsaPublicKeyInputValid bits capacity exponent-value)
      (let
        [width : i64 (byte_buf.bytes-length modulus)]
        [modulus-value : RsaPublicInteger
          (integer-from-bytes-in-class modulus capacity width)]
        [n0-inverse : u64
          (montgomery-n0-inverse (array-ref modulus-value.limbs 0))]
        [r-squared : RsaPublicInteger (montgomery-r-squared (& modulus-value))]
        (OkRsaPublicKey
          (RsaPublicKey
            modulus-value
            r-squared
            exponent-value
            bits
            (class-bits-for-limbs capacity)
            n0-inverse)))]))

;: Parse canonical unsigned public modulus and exponent magnitudes.
(define (parse-public-key
  [modulus : (& modulus bytes)]
  [exponent : (& exponent bytes)]) : ResultRsaPublicKey
  (parse-public-key-signed modulus false exponent false))

;: Recheck the complete prepared-key shape before any public operation uses
;: dynamic-array indices. This protects the module boundary even if a caller
;: directly constructs or mutates the public record representation.
(define (public-key-state-valid? [key : (& key RsaPublicKey)]) : bool
  (let
    [capacity : i64 key.modulus.capacity]
    [count : i64 key.modulus.limb-count]
    [width : i64 key.modulus.octet-width]
    (cond
      [(or
          (= (class-bits-for-limbs capacity) 0)
          (!= (array-length key.modulus.limbs) capacity)
          (!= (array-length key.r-squared.limbs) capacity)
          (!= key.r-squared.capacity capacity)
          (!= key.r-squared.octet-width width))
        false]
      [(or
          (<= count 0)
          (> count capacity)
          (!= count (/ (+ width 3) 4))
          (!= count (normalized-limb-count (& key.modulus.limbs) count))
          (< key.r-squared.limb-count 0)
          (> key.r-squared.limb-count count)
          (!=
            key.r-squared.limb-count
            (normalized-limb-count
              (& key.r-squared.limbs)
              key.r-squared.limb-count)))
        false]
      [else
        (let
          [low : u64 (cast (array-ref key.modulus.limbs 0) : u64)]
          [top : u64 (cast (array-ref key.modulus.limbs (- count 1)) : u64)]
          [actual-bits : i64 (+ (* (- count 1) 32) (exponent-bit-length top))]
          (and
            (>= actual-bits rsa-minimum-modulus-bits)
            (<= actual-bits rsa-maximum-modulus-bits)
            (= key.modulus-bits actual-bits)
            (= width (/ (+ actual-bits 7) 8))
            (= capacity (class-limbs-for-bits actual-bits))
            (= key.class-bits (class-bits-for-limbs capacity))
            (!= (bit-and low (cast 1 : u64)) (cast 0 : u64))
            (>= key.exponent (cast 3 : u64))
            (<= key.exponent rsa-maximum-public-exponent)
            (!= (bit-and key.exponent (cast 1 : u64)) (cast 0 : u64))
            (= (bit-and (* low key.n0-inverse) rsa-limb-mask) rsa-limb-mask)
            (> key.r-squared.limb-count 0)
            (<
              (compare-limbs
                (& key.r-squared.limbs)
                (& key.modulus.limbs)
                count)
              0)))])))

;: Serialize one nonnegative integer to exactly its retained octet width.
(define (integer-to-bytes [value : (& value RsaPublicInteger)]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity value.octet-width)]
    [output-index : i64 0]
    (begin
      (while (< output-index value.octet-width)
        (let
          [from-end : i64 (- (- value.octet-width 1) output-index)]
          [limb-index : i64 (/ from-end 4)]
          [shift : i64 (* (% from-end 4) 8)]
          [byte : u8
            (cast
              (bit-and
                (shr (cast (array-ref value.limbs limb-index) : u64) shift)
                (cast 255 : u64))
              : u8)]
          (begin
            (set! out (byte_buf.push out byte))
            (set! output-index (+ output-index 1)))))
      out)))

;: Raise one exact-width public representative to the checked public exponent.
(define (public-exponentiate
  [key : (& key RsaPublicKey)]
  [representative : (& representative bytes)]) : ResultRsaPublicBytes
  (if (not (public-key-state-valid? key))
    (ErrRsaPublicBytes (rsa-error (RsaArithmeticInvariant) 0))
    (let
      [length : i64 (byte_buf.bytes-length representative)]
      (if (!= length key.modulus.octet-width)
        (ErrRsaPublicBytes (rsa-error (RsaInvalidRepresentativeLength) length))
        (let
          [normal : RsaPublicInteger
            (integer-from-bytes-in-class
              representative
              key.modulus.capacity
              key.modulus.octet-width)]
          (if (>=
            (compare-limbs
              (& normal.limbs)
              (& key.modulus.limbs)
              key.modulus.limb-count)
            0)
            (ErrRsaPublicBytes (rsa-error (RsaRepresentativeOutOfRange) length))
            (let
              [base : RsaPublicInteger (to-montgomery (& normal) key)]
              [one : RsaPublicInteger (one-like (& key.modulus))]
              [result : RsaPublicInteger (to-montgomery (& one) key)]
              [bit : i64 (- (exponent-bit-length key.exponent) 1)]
              (begin
                (while (>= bit 0)
                  (begin
                    (set!
                      result
                      (montgomery-multiply
                        (& result)
                        (& result)
                        (& key.modulus)
                        key.n0-inverse))
                    (if (!=
                      (bit-and (shr key.exponent bit) (cast 1 : u64))
                      (cast 0 : u64))
                      (set!
                        result
                        (montgomery-multiply
                          (& result)
                          (& base)
                          (& key.modulus)
                          key.n0-inverse))
                      unit)
                    (set! bit (- bit 1))))
                (let
                  [finished : RsaPublicInteger (from-montgomery (& result) key)]
                  (OkRsaPublicBytes (integer-to-bytes (& finished))))))))))))

(test
  crypto-rsa-core-small-montgomery
  (let
    [modulus : RsaPublicInteger (zero-integer 64 256)]
    [left : RsaPublicInteger (zero-integer 64 256)]
    [right : RsaPublicInteger (zero-integer 64 256)]
    [sum : RsaPublicInteger (zero-integer 64 256)]
    (begin
      (set! (array-ref modulus.limbs 0) (cast 17 : u32))
      (set! modulus.limb-count 1)
      (set! (array-ref left.limbs 0) (cast 5 : u32))
      (set! left.limb-count 1)
      (set! (array-ref right.limbs 0) (cast 7 : u32))
      (set! right.limb-count 1)
      (set! (array-ref sum.limbs 0) (cast 13 : u32))
      (set! sum.limb-count 1)
      (add-modulus! (&mut sum) (& right) (& modulus))
      (test.assert-i64-eq
        (cast (array-ref sum.limbs 0) : i64)
        3
        "RSA bounded add and conditional subtract")
      (let
        [inverse : u64 (montgomery-n0-inverse (cast 17 : u32))]
        [r-squared : RsaPublicInteger (montgomery-r-squared (& modulus))]
        [key : RsaPublicKey
          (RsaPublicKey modulus r-squared (cast 3 : u64) 2048 2048 inverse)]
        [left-mont : RsaPublicInteger (to-montgomery (& left) (& key))]
        [right-mont : RsaPublicInteger (to-montgomery (& right) (& key))]
        [product-mont : RsaPublicInteger
          (montgomery-multiply
            (& left-mont)
            (& right-mont)
            (& key.modulus)
            key.n0-inverse)]
        [product : RsaPublicInteger (from-montgomery (& product-mont) (& key))]
        (begin
          (test.assert-i64-eq
            (cast (array-ref product.limbs 0) : i64)
            1
            "RSA small Montgomery product")
          (test.assert-true
            (=
              (bit-and
                (* (cast (array-ref key.modulus.limbs 0) : u64) key.n0-inverse)
                rsa-limb-mask)
              rsa-limb-mask)
            "RSA Montgomery inverse"))))))