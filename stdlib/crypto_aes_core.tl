;# Internal shared forward AES-128/AES-256 block primitive.
;#
;# Consuming `new-128`/`new-256` constructors validate exact live SecretFixed
;# keys and allocate one expanded schedule before reading a key byte. They
;# immediately close the raw key after expansion. Borrowed typed block calls
;# require disjoint live exact-16 source/destination owners and allocate nothing.
;# Byte order is FIPS 197: state[r,c] = input[r + 4*c], and schedule words are
;# four successive bytes in specification order, independent of host endianness.
;#
;# The shared S-box computes x^254 in GF(2^8), then the FIPS affine transform.
;# All multiplication steps, round counts and byte addresses depend only on
;# public variant/loop indices. Volatile word stores wipe fixed local scratch.
;# Code-shape and paired-work checks are regression evidence, not a timing proof
;# or side-channel audit. Fatal OOM/panic/abort and register/cache/dump erasure
;# are outside the cleanup guarantee. This is not an ECB mode or policy API.
;#
;# Usage: `(import stdlib.crypto_aes_core)`
;#
;# This internal example lends a schedule and two secret block owners to the
;# primitive, then discharges all three owners on either structured result.
;#
;# ```typelisp
;# (import stdlib.crypto_aes_core as aes)
;# (import stdlib.crypto_secret as secret)
;# (define (main) : i64
;#   (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
;#     [(aes.Aes128Ok schedule)
;#       (with
;#         ([live schedule aes.close-128]
;#          [source (secret.fixed-zero (secret.Secret16)) secret.close-fixed]
;#          [destination (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
;#         (match (aes.encrypt-128! (& live) (& source) (&mut destination))
;#           [(aes.AesOk) 42]
;#           [(aes.AesErr _) 1]))]
;#     [(aes.Aes128Err _) 1]))
;# ```
(import stdlib.crypto_secret as secret)
(cfg test (import stdlib.test))

;: Test-only tally of visited source work sites, never secret values. Each
;: primitive/loop site contributes its documented arithmetic or byte-work units.
;: The owner is the AES regression suite; production builds contain no tally.
(cfg
  test
  (define source-work : i64
    0))

;: Public failures; no payload contains key, schedule or state bytes.
(defenum AesError
  (AesSecret secret.SecretError)
  (AesInvalidSchedule)
  (AesOverlap))

;: All validation completes before destination mutation.
(defenum AesStatus
  (:must-use)
  (AesOk)
  (AesErr AesError))

;: Nominal ownership transfer from a cleanup-owning local into a constructor.
(defstruct RawKey
  (:cleanup close-raw-key)
  (value secret.SecretFixed (:owned)))

;: The sole cleanup obligation for a 176-byte AES-128 expanded schedule.
(defstruct Aes128Schedule
  (:cleanup close-128)
  (expanded secret.SecretBytes (:owned)))

;: The sole cleanup obligation for a 240-byte AES-256 expanded schedule.
(defstruct Aes256Schedule
  (:cleanup close-256)
  (expanded secret.SecretBytes (:owned)))

;: AES-128 construction, owning its success payload.
(defenum Aes128Result
  (:cleanup close-128-result)
  (:must-use)
  (Aes128Ok Aes128Schedule (:owned))
  (Aes128Err AesError))

;: AES-256 construction, owning its success payload.
(defenum Aes256Result
  (:cleanup close-256-result)
  (:must-use)
  (Aes256Ok Aes256Schedule (:owned))
  (Aes256Err AesError))

;: Multiply by x modulo x^8+x^4+x^3+x+1, without a data branch.
(define (xtime [value : u8]) : u8
  (cfg test (set! source-work (+ source-work 5)) unit)
  (bit-xor
    (shl value (cast 1 : u64))
    (bit-and (cast 27 : u8) (- (cast 0 : u8) (shr value (cast 7 : u64))))))

;: Eight masked steps, including zero inputs; no secret-indexed table.
(define (gf-mul [left : u8] [right : u8]) : u8
  (let
    [a : u8 left]
    [b : u8 right]
    [product : u8 (cast 0 : u8)]
    [step : i64 0]
    (while (< step 8)
      (cfg test (set! source-work (+ source-work 6)) unit)
      (set!
        product
        (bit-xor
          product
          (bit-and a (- (cast 0 : u8) (bit-and b (cast 1 : u8))))))
      (set! a (xtime a))
      (set! b (shr b (cast 1 : u64)))
      (set! step (+ step 1)))
    product))

;: FIPS 197 Table 4, computed by the fixed x^254 chain and affine transform.
(define (sbox [value : u8]) : u8
  (cfg test (set! source-work (+ source-work 17)) unit)
  (let
    [x2 : u8 (gf-mul value value)]
    [x3 : u8 (gf-mul x2 value)]
    [x6 : u8 (gf-mul x3 x3)]
    [x12 : u8 (gf-mul x6 x6)]
    [x15 : u8 (gf-mul x12 x3)]
    [x30 : u8 (gf-mul x15 x15)]
    [x60 : u8 (gf-mul x30 x30)]
    [x120 : u8 (gf-mul x60 x60)]
    [x240 : u8 (gf-mul x120 x120)]
    [x252 : u8 (gf-mul x240 x12)]
    [inverse : u8 (gf-mul x252 x2)]
    (bit-xor
      (bit-xor
        (bit-xor
          inverse
          (bit-or (shl inverse (cast 1 : u64)) (shr inverse (cast 7 : u64))))
        (bit-or (shl inverse (cast 2 : u64)) (shr inverse (cast 6 : u64))))
      (bit-xor
        (bit-xor
          (bit-or (shl inverse (cast 3 : u64)) (shr inverse (cast 5 : u64)))
          (bit-or (shl inverse (cast 4 : u64)) (shr inverse (cast 4 : u64))))
        (cast 99 : u8)))))

;: Expand validated disjoint key/schedule regions. `key-length` is 16 or 32;
;: `length` is respectively 176 or 240. Every index and branch is public.
(unsafe
  (define (expand!
    [key : (Ptr u8)]
    [output : (MutPtr u8)]
    [key-length : i64]
    [length : i64]) : unit
    (let
      [scratch : (Array u64 1) (make-array u64 1)]
      [temp : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u8)))]
      [index : i64 0]
      [rcon : u8 (cast 1 : u8)]
      (while (< index key-length)
        (cfg test (set! source-work (+ source-work 2)) unit)
        (unsafe
          (ptr-write!
            (ptr-offset output index)
            (ptr-read (ptr-offset key index))))
        (set! index (+ index 1)))
      (while (< index length)
        (cfg test (set! source-work (+ source-work 26)) unit)
        (let
          [byte : i64 0]
          (while (< byte 4)
            (unsafe
              (ptr-write!
                (ptr-offset temp byte)
                (ptr-read (ptr-offset output (+ (- index 4) byte)))))
            (set! byte (+ byte 1))))
        (cond
          [(= (% index key-length) 0)
            (let
              [first : u8
                (unsafe
                  (ptr-read temp))]
              (unsafe
                (ptr-write!
                  temp
                  (bit-xor (sbox (ptr-read (ptr-offset temp 1))) rcon)))
              (unsafe
                (ptr-write!
                  (ptr-offset temp 1)
                  (sbox (ptr-read (ptr-offset temp 2)))))
              (unsafe
                (ptr-write!
                  (ptr-offset temp 2)
                  (sbox (ptr-read (ptr-offset temp 3)))))
              (unsafe
                (ptr-write! (ptr-offset temp 3) (sbox first)))
              (set! rcon (xtime rcon)))]
          [(and (= key-length 32) (= (% index 32) 16))
            (let
              [byte : i64 0]
              (while (< byte 4)
                (unsafe
                  (ptr-write!
                    (ptr-offset temp byte)
                    (sbox (ptr-read (ptr-offset temp byte)))))
                (set! byte (+ byte 1))))]
          [else unit])
        (let
          [byte : i64 0]
          (while (< byte 4)
            (unsafe
              (ptr-write!
                (ptr-offset output (+ index byte))
                (bit-xor
                  (ptr-read (ptr-offset output (+ (- index key-length) byte)))
                  (ptr-read (ptr-offset temp byte)))))
            (set! byte (+ byte 1))))
        (set! index (+ index 4)))
      (unsafe
        (secret.wipe-words! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 1)))))

;: Apply one round key to all sixteen state bytes, using public offsets only.
(unsafe
  (define (add-round-key!
    [state : (MutPtr u8)]
    [schedule : (Ptr u8)]
    [round : i64]) : unit
    (let
      [index : i64 0]
      (while (< index 16)
        (cfg test (set! source-work (+ source-work 4)) unit)
        (unsafe
          (ptr-write!
            (ptr-offset state index)
            (bit-xor
              (ptr-read (ptr-offset state index))
              (ptr-read (ptr-offset schedule (+ (* round 16) index))))))
        (set! index (+ index 1))))))

;: Apply the shared computed S-box to all sixteen bytes.
(unsafe
  (define (sub-bytes! [state : (MutPtr u8)]) : unit
    (let
      [index : i64 0]
      (while (< index 16)
        (cfg test (set! source-work (+ source-work 2)) unit)
        (unsafe
          (ptr-write!
            (ptr-offset state index)
            (sbox (ptr-read (ptr-offset state index)))))
        (set! index (+ index 1))))))

;: Rotate each row using only fixed public addresses in column-major storage.
(unsafe
  (define (shift-rows! [state : (MutPtr u8)]) : unit
    (cfg test (set! source-work (+ source-work 66)) unit)
    (let
      [scratch : (Array u64 2) (make-array u64 2)]
      [copy : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u8)))]
      [index : i64 0]
      (while (< index 16)
        (unsafe
          (ptr-write!
            (ptr-offset copy index)
            (ptr-read (ptr-offset state index))))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index 16)
        (let
          [row : i64 (% index 4)]
          [column : i64 (/ index 4)]
          (unsafe
            (ptr-write!
              (ptr-offset state index)
              (ptr-read (ptr-offset copy (+ row (* 4 (% (+ column row) 4))))))))
        (set! index (+ index 1)))
      (unsafe
        (secret.wipe-words! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 2)))))

;: Mix four columns with branch-free multiplication by x.
(unsafe
  (define (mix-columns! [state : (MutPtr u8)]) : unit
    (cfg test (set! source-work (+ source-work 60)) unit)
    (let
      [column : i64 0]
      (while (< column 4)
        (let
          [base : (MutPtr u8)
            (unsafe
              (ptr-offset state (* column 4)))]
          [a : u8
            (unsafe
              (ptr-read base))]
          [b : u8
            (unsafe
              (ptr-read (ptr-offset base 1)))]
          [c : u8
            (unsafe
              (ptr-read (ptr-offset base 2)))]
          [d : u8
            (unsafe
              (ptr-read (ptr-offset base 3)))]
          [all : u8 (bit-xor (bit-xor a b) (bit-xor c d))]
          (unsafe
            (ptr-write! base (bit-xor (bit-xor a all) (xtime (bit-xor a b)))))
          (unsafe
            (ptr-write!
              (ptr-offset base 1)
              (bit-xor (bit-xor b all) (xtime (bit-xor b c)))))
          (unsafe
            (ptr-write!
              (ptr-offset base 2)
              (bit-xor (bit-xor c all) (xtime (bit-xor c d)))))
          (unsafe
            (ptr-write!
              (ptr-offset base 3)
              (bit-xor (bit-xor d all) (xtime (bit-xor d a))))))
        (set! column (+ column 1))))))

;: Validated 10/14-round forward core. Publish only the finished ciphertext;
;: no allocation, owner mutation, checked indexing or recoverable work occurs.
(unsafe
  (define (cipher!
    [schedule : (Ptr u8)]
    [source : (Ptr u8)]
    [destination : (MutPtr u8)]
    [rounds : i64]) : unit
    (cfg test (set! source-work (+ source-work 66)) unit)
    (let
      [scratch : (Array u64 2) (make-array u64 2)]
      [state : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u8)))]
      [index : i64 0]
      [round : i64 1]
      (while (< index 16)
        (unsafe
          (ptr-write!
            (ptr-offset state index)
            (ptr-read (ptr-offset source index))))
        (set! index (+ index 1)))
      (unsafe
        (add-round-key! state schedule 0))
      (while (< round rounds)
        (unsafe
          (sub-bytes! state))
        (unsafe
          (shift-rows! state))
        (unsafe
          (mix-columns! state))
        (unsafe
          (add-round-key! state schedule round))
        (set! round (+ round 1)))
      (unsafe
        (sub-bytes! state))
      (unsafe
        (shift-rows! state))
      (unsafe
        (add-round-key! state schedule rounds))
      (set! index 0)
      (while (< index 16)
        (unsafe
          (ptr-write!
            (ptr-offset destination index)
            (ptr-read (ptr-offset state index))))
        (set! index (+ index 1)))
      (unsafe
        (secret.wipe-words! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 2)))))

;: Require exact live fixed storage, including its public capacity.
(define (check-fixed [owner : (& owner secret.SecretFixed)] [length : i64]) : secret.SecretStatus
  (cond
    [(not
        (unsafe
          (secret.storage-live? owner.storage owner.generation)))
      (secret.SecretErr (secret.SecretClosed))]
    [(or
        (not (= (secret.fixed-length owner) length))
        (not
          (=
            (unsafe
              (secret.live-capacity owner.storage owner.generation))
            length)))
      (secret.SecretErr
        (secret.SecretLengthMismatch length (secret.fixed-length owner)))]
    [else (secret.SecretOk)]))

;: Checked construction with all recoverable operations before key reads.
;: A stale/closed handle owns no live generation to close. A live nested key
;: closes on every structured return, including success and bad-size rejection.
(unsafe
  (define (construct-schedule
    [input : RawKey]
    [key-length : i64]
    [length : i64]) : secret.SecretBytesResult
    (when
      (not
        (unsafe
          (secret.storage-live? input.value.storage input.value.generation)))
      (return (secret.SecretBytesErr (secret.SecretClosed))))
    (with
      ([key input.value secret.close-fixed])
      (match (check-fixed (& key) key-length)
        [(SecretErr error) (secret.SecretBytesErr error)]
        [(SecretOk)
          (match (secret.bytes-new length)
            [(SecretBytesErr error) (secret.SecretBytesErr error)]
            [(SecretBytesOk expanded)
              (match (unsafe
                (secret.bytes-set-length! (&mut expanded) length))
                [(SecretErr error)
                  (secret.close-bytes expanded)
                  (secret.SecretBytesErr error)]
                [(SecretOk)
                  (unsafe
                    (expand!
                      (ptr-cast (secret.storage-data key.storage) : (Ptr u8))
                      (secret.storage-data expanded.storage)
                      key-length
                      length))
                  (secret.SecretBytesOk expanded)])])]))))

;: Checked implementation of the consuming AES-128 constructor.
(define (construct-128 [input : RawKey]) : Aes128Result
  (match (unsafe
    (construct-schedule input 16 176))
    [(SecretBytesOk expanded) (Aes128Ok (Aes128Schedule expanded))]
    [(SecretBytesErr error) (Aes128Err (AesSecret error))]))

;: Checked implementation of the consuming AES-256 constructor.
(define (construct-256 [input : RawKey]) : Aes256Result
  (match (unsafe
    (construct-schedule input 32 240))
    [(SecretBytesOk expanded) (Aes256Ok (Aes256Schedule expanded))]
    [(SecretBytesErr error) (Aes256Err (AesSecret error))]))

;: Consume an exact live 16-byte key through the nominal owner-transfer seam.
(defmacro (new-128 [key : Expr]) : Aes128Result
  `(construct-128 (RawKey ,key)))

;: Consume an exact live 32-byte key through the nominal owner-transfer seam.
(defmacro (new-256 [key : Expr]) : Aes256Result
  `(construct-256 (RawKey ,key)))

;: Whether two validated backing ranges overlap; subtraction avoids overflow.
(unsafe
  (define (overlap?
    [left : (Ptr u8)]
    [left-length : i64]
    [right : (Ptr u8)]
    [right-length : i64]) : bool
    (let
      [a : u64
        (unsafe
          (ptr->int left))]
      [b : u64
        (unsafe
          (ptr->int right))]
      (if (<= a b)
        (< (- b a) (cast left-length : u64))
        (< (- a b) (cast right-length : u64))))))

;: Only the typed wrappers call this with public matching schedule/round sizes.
;: Validate all metadata and disjointness before the first secret read/write.
(unsafe
  (define (encrypt-checked!
    [expanded : (& expanded secret.SecretBytes)]
    [source : (& source secret.SecretFixed)]
    [destination : (&mut destination secret.SecretFixed)]
    [length : i64]
    [rounds : i64]) : AesStatus
    (cond
      [(not
          (unsafe
            (secret.storage-live? expanded.storage expanded.generation)))
        (AesErr (AesSecret (secret.SecretClosed)))]
      [(or
          (not (= (secret.bytes-length expanded) length))
          (not (= (secret.bytes-capacity expanded) length)))
        (AesErr (AesInvalidSchedule))]
      [else
        (match (check-fixed source 16)
          [(SecretErr error) (AesErr (AesSecret error))]
          [(SecretOk)
            (match (check-fixed destination 16)
              [(SecretErr error) (AesErr (AesSecret error))]
              [(SecretOk)
                (let
                  [keys : (Ptr u8)
                    (unsafe
                      (ptr-cast
                        (secret.storage-data expanded.storage)
                        : (Ptr u8)))]
                  [input : (Ptr u8)
                    (unsafe
                      (ptr-cast (secret.storage-data source.storage) : (Ptr u8)))]
                  [output : (MutPtr u8)
                    (unsafe
                      (secret.storage-data destination.storage))]
                  [output-read : (Ptr u8)
                    (unsafe
                      (ptr-cast output : (Ptr u8)))]
                  (if (or
                    (= source.storage destination.storage)
                    (unsafe
                      (overlap? input 16 output-read 16))
                    (unsafe
                      (overlap? keys length input 16))
                    (unsafe
                      (overlap? keys length output-read 16)))
                    (AesErr (AesOverlap))
                    (begin
                      (unsafe
                        (cipher! keys input output rounds))
                      (AesOk))))])])])))

;: Borrow a live AES-128 schedule repeatedly; exact-16 owners must be disjoint.
(define (encrypt-128!
  [schedule : (& schedule Aes128Schedule)]
  [source : (& source secret.SecretFixed)]
  [destination : (&mut destination secret.SecretFixed)]) : AesStatus
  (unsafe
    (encrypt-checked! (& schedule.expanded) source destination 176 10)))

;: Borrow a live AES-256 schedule repeatedly; exact-16 owners must be disjoint.
(define (encrypt-256!
  [schedule : (& schedule Aes256Schedule)]
  [source : (& source secret.SecretFixed)]
  [destination : (&mut destination secret.SecretFixed)]) : AesStatus
  (unsafe
    (encrypt-checked! (& schedule.expanded) source destination 240 14)))

(cfg
  test
  (test
    aes-core-field-arithmetic
    (begin
      (test.assert-true
        (= (xtime (cast 0x80 : u8)) (cast 0x1b : u8))
        "FIPS reduction polynomial")
      (test.assert-true
        (= (sbox (cast 0 : u8)) (cast 0x63 : u8))
        "zero inverse convention")
      (test.assert-true
        (= (sbox (cast 0x53 : u8)) (cast 0xed : u8))
        "FIPS S-box example"))))