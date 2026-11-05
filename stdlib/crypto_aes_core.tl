;# Internal shared forward AES-128/AES-256 block primitive.
;#
;# Consuming `new-128`/`new-256` constructors validate exact live SecretFixed
;# keys and allocate one expanded schedule before reading a key byte. They
;# immediately close the raw key after expansion. Borrowed typed block calls
;# require disjoint live exact-16 source/destination owners and allocate nothing.
;# Byte order is FIPS 197: state[r,c] = input[r + 4*c], and schedule words are
;# four successive bytes in specification order, independent of host endianness.
;#
;# Rounds run on eight local bit planes: plane j bit 4c+r holds bit j of
;# state[r,c]. One Boyar-Peralta Boolean circuit substitutes all sixteen lanes
;# at once, and key expansion runs SubWord through the same circuit. There is
;# no lookup table; every gate, shift, mask, round count and byte address
;# depends only on public variant/loop indices. Volatile word stores wipe fixed
;# local scratch.
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

;: Transpose an 8x8 bit matrix in place: bit 8*i+j moves to bit 8*j+i.
(define (transpose-8x8 [value : u64]) : u64
  (cfg test (set! source-work (+ source-work 18)) unit)
  (let
    [x : u64 value]
    [t : u64 (bit-and (bit-xor x (shr x 7)) 0x00aa00aa00aa00aa)]
    (set! x (bit-xor x t (shl t 7)))
    (set! t (bit-and (bit-xor x (shr x 14)) 0x0000cccc0000cccc))
    (set! x (bit-xor x t (shl t 14)))
    (set! t (bit-and (bit-xor x (shr x 28)) 0x00000000f0f0f0f0))
    (bit-xor x t (shl t 28))))

;: XOR sixteen FIPS-order bytes into bit planes: plane j bit i is bit j of
;: byte i = r + 4c. `keep` is the public mask 0 (load) or all ones (XOR).
(unsafe
  (define (absorb! [bytes : (Ptr u8)] [slices : (MutPtr u64)] [keep : u64]) : unit
    (cfg test (set! source-work (+ source-work 114)) unit)
    (let
      [low : u64
        (transpose-8x8
          (unsafe
            (bit-or
              (cast (ptr-read bytes) : u64)
              (shl (cast (ptr-read (ptr-offset bytes 1)) : u64) 8)
              (shl (cast (ptr-read (ptr-offset bytes 2)) : u64) 16)
              (shl (cast (ptr-read (ptr-offset bytes 3)) : u64) 24)
              (shl (cast (ptr-read (ptr-offset bytes 4)) : u64) 32)
              (shl (cast (ptr-read (ptr-offset bytes 5)) : u64) 40)
              (shl (cast (ptr-read (ptr-offset bytes 6)) : u64) 48)
              (shl (cast (ptr-read (ptr-offset bytes 7)) : u64) 56))))]
      [high : u64
        (transpose-8x8
          (unsafe
            (bit-or
              (cast (ptr-read (ptr-offset bytes 8)) : u64)
              (shl (cast (ptr-read (ptr-offset bytes 9)) : u64) 8)
              (shl (cast (ptr-read (ptr-offset bytes 10)) : u64) 16)
              (shl (cast (ptr-read (ptr-offset bytes 11)) : u64) 24)
              (shl (cast (ptr-read (ptr-offset bytes 12)) : u64) 32)
              (shl (cast (ptr-read (ptr-offset bytes 13)) : u64) 40)
              (shl (cast (ptr-read (ptr-offset bytes 14)) : u64) 48)
              (shl (cast (ptr-read (ptr-offset bytes 15)) : u64) 56))))]
      (unsafe
        (ptr-write!
          slices
          (bit-xor
            (bit-and (ptr-read slices) keep)
            (bit-and low 0xff)
            (shl (bit-and high 0xff) 8))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 1)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 1)) keep)
            (bit-and (shr low 8) 0xff)
            (bit-and high 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 2)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 2)) keep)
            (bit-and (shr low 16) 0xff)
            (bit-and (shr high 8) 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 3)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 3)) keep)
            (bit-and (shr low 24) 0xff)
            (bit-and (shr high 16) 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 4)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 4)) keep)
            (bit-and (shr low 32) 0xff)
            (bit-and (shr high 24) 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 5)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 5)) keep)
            (bit-and (shr low 40) 0xff)
            (bit-and (shr high 32) 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 6)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 6)) keep)
            (bit-and (shr low 48) 0xff)
            (bit-and (shr high 40) 0xff00))))
      (unsafe
        (ptr-write!
          (ptr-offset slices 7)
          (bit-xor
            (bit-and (ptr-read (ptr-offset slices 7)) keep)
            (bit-and (shr low 56) 0xff)
            (bit-and (shr high 48) 0xff00)))))))

;: Inverse of `absorb!`: write the sixteen FIPS-order bytes of the planes.
(unsafe
  (define (squeeze! [slices : (Ptr u64)] [bytes : (MutPtr u8)]) : unit
    (cfg test (set! source-work (+ source-work 91)) unit)
    (let
      [low : u64
        (transpose-8x8
          (unsafe
            (bit-or
              (bit-and (ptr-read slices) 0xff)
              (shl (bit-and (ptr-read (ptr-offset slices 1)) 0xff) 8)
              (shl (bit-and (ptr-read (ptr-offset slices 2)) 0xff) 16)
              (shl (bit-and (ptr-read (ptr-offset slices 3)) 0xff) 24)
              (shl (bit-and (ptr-read (ptr-offset slices 4)) 0xff) 32)
              (shl (bit-and (ptr-read (ptr-offset slices 5)) 0xff) 40)
              (shl (bit-and (ptr-read (ptr-offset slices 6)) 0xff) 48)
              (shl (bit-and (ptr-read (ptr-offset slices 7)) 0xff) 56))))]
      [high : u64
        (transpose-8x8
          (unsafe
            (bit-or
              (bit-and (shr (ptr-read slices) 8) 0xff)
              (bit-and (ptr-read (ptr-offset slices 1)) 0xff00)
              (shl (bit-and (ptr-read (ptr-offset slices 2)) 0xff00) 8)
              (shl (bit-and (ptr-read (ptr-offset slices 3)) 0xff00) 16)
              (shl (bit-and (ptr-read (ptr-offset slices 4)) 0xff00) 24)
              (shl (bit-and (ptr-read (ptr-offset slices 5)) 0xff00) 32)
              (shl (bit-and (ptr-read (ptr-offset slices 6)) 0xff00) 40)
              (shl (bit-and (ptr-read (ptr-offset slices 7)) 0xff00) 48))))]
      (unsafe
        (ptr-write! bytes (cast low : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 1) (cast (shr low 8) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 2) (cast (shr low 16) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 3) (cast (shr low 24) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 4) (cast (shr low 32) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 5) (cast (shr low 40) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 6) (cast (shr low 48) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 7) (cast (shr low 56) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 8) (cast high : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 9) (cast (shr high 8) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 10) (cast (shr high 16) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 11) (cast (shr high 24) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 12) (cast (shr high 32) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 13) (cast (shr high 40) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 14) (cast (shr high 48) : u8)))
      (unsafe
        (ptr-write! (ptr-offset bytes 15) (cast (shr high 56) : u8))))))

;: Boyar-Peralta Boolean S-box circuit on eight bit planes: 32 AND and 87
;: XOR gates, with lane-masked XORs for the four inversions. All sixteen lanes
;: take the same gates; no secret value selects a table, branch or address.
(unsafe
  (define (sub-bytes! [state : (MutPtr u64)]) : unit
    (cfg test (set! source-work (+ source-work 135)) unit)
    (let
      [lanes : u64 0xffff]
      [x7 : u64
        (unsafe
          (ptr-read state))]
      [x6 : u64
        (unsafe
          (ptr-read (ptr-offset state 1)))]
      [x5 : u64
        (unsafe
          (ptr-read (ptr-offset state 2)))]
      [x4 : u64
        (unsafe
          (ptr-read (ptr-offset state 3)))]
      [x3 : u64
        (unsafe
          (ptr-read (ptr-offset state 4)))]
      [x2 : u64
        (unsafe
          (ptr-read (ptr-offset state 5)))]
      [x1 : u64
        (unsafe
          (ptr-read (ptr-offset state 6)))]
      [x0 : u64
        (unsafe
          (ptr-read (ptr-offset state 7)))]
      [y14 : u64 (bit-xor x3 x5)]
      [y13 : u64 (bit-xor x0 x6)]
      [y9 : u64 (bit-xor x0 x3)]
      [y8 : u64 (bit-xor x0 x5)]
      [t0 : u64 (bit-xor x1 x2)]
      [y1 : u64 (bit-xor t0 x7)]
      [y4 : u64 (bit-xor y1 x3)]
      [y12 : u64 (bit-xor y13 y14)]
      [y2 : u64 (bit-xor y1 x0)]
      [y5 : u64 (bit-xor y1 x6)]
      [y3 : u64 (bit-xor y5 y8)]
      [t1 : u64 (bit-xor x4 y12)]
      [y15 : u64 (bit-xor t1 x5)]
      [y20 : u64 (bit-xor t1 x1)]
      [y6 : u64 (bit-xor y15 x7)]
      [y10 : u64 (bit-xor y15 t0)]
      [y11 : u64 (bit-xor y20 y9)]
      [y7 : u64 (bit-xor x7 y11)]
      [y17 : u64 (bit-xor y10 y11)]
      [y19 : u64 (bit-xor y10 y8)]
      [y16 : u64 (bit-xor t0 y11)]
      [y21 : u64 (bit-xor y13 y16)]
      [y18 : u64 (bit-xor x0 y16)]
      [t2 : u64 (bit-and y12 y15)]
      [t3 : u64 (bit-and y3 y6)]
      [t4 : u64 (bit-xor t3 t2)]
      [t5 : u64 (bit-and y4 x7)]
      [t6 : u64 (bit-xor t5 t2)]
      [t7 : u64 (bit-and y13 y16)]
      [t8 : u64 (bit-and y5 y1)]
      [t9 : u64 (bit-xor t8 t7)]
      [t10 : u64 (bit-and y2 y7)]
      [t11 : u64 (bit-xor t10 t7)]
      [t12 : u64 (bit-and y9 y11)]
      [t13 : u64 (bit-and y14 y17)]
      [t14 : u64 (bit-xor t13 t12)]
      [t15 : u64 (bit-and y8 y10)]
      [t16 : u64 (bit-xor t15 t12)]
      [t17 : u64 (bit-xor t4 t14)]
      [t18 : u64 (bit-xor t6 t16)]
      [t19 : u64 (bit-xor t9 t14)]
      [t20 : u64 (bit-xor t11 t16)]
      [t21 : u64 (bit-xor t17 y20)]
      [t22 : u64 (bit-xor t18 y19)]
      [t23 : u64 (bit-xor t19 y21)]
      [t24 : u64 (bit-xor t20 y18)]
      [t25 : u64 (bit-xor t21 t22)]
      [t26 : u64 (bit-and t21 t23)]
      [t27 : u64 (bit-xor t24 t26)]
      [t28 : u64 (bit-and t25 t27)]
      [t29 : u64 (bit-xor t28 t22)]
      [t30 : u64 (bit-xor t23 t24)]
      [t31 : u64 (bit-xor t22 t26)]
      [t32 : u64 (bit-and t31 t30)]
      [t33 : u64 (bit-xor t32 t24)]
      [t34 : u64 (bit-xor t23 t33)]
      [t35 : u64 (bit-xor t27 t33)]
      [t36 : u64 (bit-and t24 t35)]
      [t37 : u64 (bit-xor t36 t34)]
      [t38 : u64 (bit-xor t27 t36)]
      [t39 : u64 (bit-and t29 t38)]
      [t40 : u64 (bit-xor t25 t39)]
      [t41 : u64 (bit-xor t40 t37)]
      [t42 : u64 (bit-xor t29 t33)]
      [t43 : u64 (bit-xor t29 t40)]
      [t44 : u64 (bit-xor t33 t37)]
      [t45 : u64 (bit-xor t42 t41)]
      [z0 : u64 (bit-and t44 y15)]
      [z1 : u64 (bit-and t37 y6)]
      [z2 : u64 (bit-and t33 x7)]
      [z3 : u64 (bit-and t43 y16)]
      [z4 : u64 (bit-and t40 y1)]
      [z5 : u64 (bit-and t29 y7)]
      [z6 : u64 (bit-and t42 y11)]
      [z7 : u64 (bit-and t45 y17)]
      [z8 : u64 (bit-and t41 y10)]
      [z9 : u64 (bit-and t44 y12)]
      [z10 : u64 (bit-and t37 y3)]
      [z11 : u64 (bit-and t33 y4)]
      [z12 : u64 (bit-and t43 y13)]
      [z13 : u64 (bit-and t40 y5)]
      [z14 : u64 (bit-and t29 y2)]
      [z15 : u64 (bit-and t42 y9)]
      [z16 : u64 (bit-and t45 y14)]
      [z17 : u64 (bit-and t41 y8)]
      [t46 : u64 (bit-xor z15 z16)]
      [t47 : u64 (bit-xor z10 z11)]
      [t48 : u64 (bit-xor z5 z13)]
      [t49 : u64 (bit-xor z9 z10)]
      [t50 : u64 (bit-xor z2 z12)]
      [t51 : u64 (bit-xor z2 z5)]
      [t52 : u64 (bit-xor z7 z8)]
      [t53 : u64 (bit-xor z0 z3)]
      [t54 : u64 (bit-xor z6 z7)]
      [t55 : u64 (bit-xor z16 z17)]
      [t56 : u64 (bit-xor z12 t48)]
      [t57 : u64 (bit-xor t50 t53)]
      [t58 : u64 (bit-xor z4 t46)]
      [t59 : u64 (bit-xor z3 t54)]
      [t60 : u64 (bit-xor t46 t57)]
      [t61 : u64 (bit-xor z14 t57)]
      [t62 : u64 (bit-xor t52 t58)]
      [t63 : u64 (bit-xor t49 t58)]
      [t64 : u64 (bit-xor z4 t59)]
      [t65 : u64 (bit-xor t61 t62)]
      [t66 : u64 (bit-xor z1 t63)]
      [s0 : u64 (bit-xor t59 t63)]
      [s6 : u64 (bit-xor t56 t62 lanes)]
      [s7 : u64 (bit-xor t48 t60 lanes)]
      [t67 : u64 (bit-xor t64 t65)]
      [s3 : u64 (bit-xor t53 t66)]
      [s4 : u64 (bit-xor t51 t66)]
      [s5 : u64 (bit-xor t47 t65)]
      [s1 : u64 (bit-xor t64 s3 lanes)]
      [s2 : u64 (bit-xor t55 t67 lanes)]
      (unsafe
        (ptr-write! state s7))
      (unsafe
        (ptr-write! (ptr-offset state 1) s6))
      (unsafe
        (ptr-write! (ptr-offset state 2) s5))
      (unsafe
        (ptr-write! (ptr-offset state 3) s4))
      (unsafe
        (ptr-write! (ptr-offset state 4) s3))
      (unsafe
        (ptr-write! (ptr-offset state 5) s2))
      (unsafe
        (ptr-write! (ptr-offset state 6) s1))
      (unsafe
        (ptr-write! (ptr-offset state 7) s0)))))

;: ShiftRows on each bit plane: row r of column c takes column c+r mod 4.
;: Fixed public shifts and masks move bit 4c+r; the plane index is public.
(unsafe
  (define (shift-rows! [state : (MutPtr u64)]) : unit
    (let
      [index : i64 0]
      (while (< index 8)
        (cfg test (set! source-work (+ source-work 21)) unit)
        (let
          [plane : u64
            (unsafe
              (ptr-read (ptr-offset state index)))]
          (unsafe
            (ptr-write!
              (ptr-offset state index)
              (bit-or
                (bit-and plane 0x1111)
                (bit-and (shr plane 4) 0x0222)
                (bit-and (shl plane 12) 0x2000)
                (bit-and (shr plane 8) 0x0044)
                (bit-and (shl plane 8) 0x4400)
                (bit-and (shr plane 12) 0x0008)
                (bit-and (shl plane 4) 0x8880)))))
        (set! index (+ index 1))))))

;: Rotate each column's rows by one in a plane: row r takes row r+1 mod 4.
(define (rotate-rows-1 [plane : u64]) : u64
  (bit-or (bit-and (shr plane 1) 0x7777) (bit-and (shl plane 3) 0x8888)))

;: Rotate each column's rows by two in a plane: row r takes row r+2 mod 4.
(define (rotate-rows-2 [plane : u64]) : u64
  (bit-or (bit-and (shr plane 2) 0x3333) (bit-and (shl plane 2) 0xcccc)))

;: MixColumns on bit planes: 2(a+a') + a' + (a''+a''') with a' = row+1. The
;: multiplication by x moves planes up and folds plane 7 into planes 0/1/3/4.
(unsafe
  (define (mix-columns! [state : (MutPtr u64)]) : unit
    (cfg test (set! source-work (+ source-work 124)) unit)
    (let
      [q0 : u64
        (unsafe
          (ptr-read state))]
      [q1 : u64
        (unsafe
          (ptr-read (ptr-offset state 1)))]
      [q2 : u64
        (unsafe
          (ptr-read (ptr-offset state 2)))]
      [q3 : u64
        (unsafe
          (ptr-read (ptr-offset state 3)))]
      [q4 : u64
        (unsafe
          (ptr-read (ptr-offset state 4)))]
      [q5 : u64
        (unsafe
          (ptr-read (ptr-offset state 5)))]
      [q6 : u64
        (unsafe
          (ptr-read (ptr-offset state 6)))]
      [q7 : u64
        (unsafe
          (ptr-read (ptr-offset state 7)))]
      [r0 : u64 (rotate-rows-1 q0)]
      [r1 : u64 (rotate-rows-1 q1)]
      [r2 : u64 (rotate-rows-1 q2)]
      [r3 : u64 (rotate-rows-1 q3)]
      [r4 : u64 (rotate-rows-1 q4)]
      [r5 : u64 (rotate-rows-1 q5)]
      [r6 : u64 (rotate-rows-1 q6)]
      [r7 : u64 (rotate-rows-1 q7)]
      [t0 : u64 (bit-xor q0 r0)]
      [t1 : u64 (bit-xor q1 r1)]
      [t2 : u64 (bit-xor q2 r2)]
      [t3 : u64 (bit-xor q3 r3)]
      [t4 : u64 (bit-xor q4 r4)]
      [t5 : u64 (bit-xor q5 r5)]
      [t6 : u64 (bit-xor q6 r6)]
      [t7 : u64 (bit-xor q7 r7)]
      (unsafe
        (ptr-write! state (bit-xor t7 r0 (rotate-rows-2 t0))))
      (unsafe
        (ptr-write! (ptr-offset state 1) (bit-xor t0 t7 r1 (rotate-rows-2 t1))))
      (unsafe
        (ptr-write! (ptr-offset state 2) (bit-xor t1 r2 (rotate-rows-2 t2))))
      (unsafe
        (ptr-write! (ptr-offset state 3) (bit-xor t2 t7 r3 (rotate-rows-2 t3))))
      (unsafe
        (ptr-write! (ptr-offset state 4) (bit-xor t3 t7 r4 (rotate-rows-2 t4))))
      (unsafe
        (ptr-write! (ptr-offset state 5) (bit-xor t4 r5 (rotate-rows-2 t5))))
      (unsafe
        (ptr-write! (ptr-offset state 6) (bit-xor t5 r6 (rotate-rows-2 t6))))
      (unsafe
        (ptr-write! (ptr-offset state 7) (bit-xor t6 r7 (rotate-rows-2 t7)))))))

;: Load sixteen bytes into cleared planes, substitute, and write them back.
;: The caller owns and wipes the eight plane words.
(unsafe
  (define (sub-block! [bytes : (MutPtr u8)] [slices : (MutPtr u64)]) : unit
    (unsafe
      (absorb! (ptr-cast bytes : (Ptr u8)) slices 0))
    (unsafe
      (sub-bytes! slices))
    (unsafe
      (squeeze! (ptr-cast slices : (Ptr u64)) bytes))))

;: Test oracle for FIPS Table 4 through the production circuit, lane zero.
(cfg
  test
  (define (sbox [value : u8]) : u8
    (let
      [scratch : (Array u64 10) (make-array u64 10)]
      [slices : (MutPtr u64)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)))]
      [bytes : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-offset slices 8) : (MutPtr u8)))]
      (unsafe
        (ptr-write! bytes value))
      (unsafe
        (sub-block! bytes slices))
      (let
        [result : u8
          (unsafe
            (ptr-read bytes))]
        (unsafe
          (secret.wipe-words! slices 10))
        result))))

;: Expand validated disjoint key/schedule regions. `key-length` is 16 or 32;
;: `length` is respectively 176 or 240. Every index and branch is public.
;: SubWord runs the shared plane circuit on the temporary word's four lanes.
(unsafe
  (define (expand!
    [key : (Ptr u8)]
    [output : (MutPtr u8)]
    [key-length : i64]
    [length : i64]) : unit
    (let
      [scratch : (Array u64 10) (make-array u64 10)]
      [slices : (MutPtr u64)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)))]
      [temp : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-offset slices 8) : (MutPtr u8)))]
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
                (ptr-write! temp (ptr-read (ptr-offset temp 1))))
              (unsafe
                (ptr-write! (ptr-offset temp 1) (ptr-read (ptr-offset temp 2))))
              (unsafe
                (ptr-write! (ptr-offset temp 2) (ptr-read (ptr-offset temp 3))))
              (cfg test (set! source-work (+ source-work 11)) unit)
              (unsafe
                (ptr-write! (ptr-offset temp 3) first))
              (unsafe
                (sub-block! temp slices))
              (unsafe
                (ptr-write! temp (bit-xor (ptr-read temp) rcon)))
              (set! rcon (xtime rcon)))]
          [(and (= key-length 32) (= (% index 32) 16))
            (unsafe
              (sub-block! temp slices))]
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
        (secret.wipe-words! slices 10)))))

;: XOR one FIPS-order round key into the planes, using public offsets only.
(unsafe
  (define (add-round-key!
    [state : (MutPtr u64)]
    [schedule : (Ptr u8)]
    [round : i64]) : unit
    (unsafe
      (absorb! (ptr-offset schedule (* round 16)) state 0xffffffffffffffff))))

;: Validated 10/14-round forward core on eight local bit planes. Publish only
;: the finished ciphertext; no allocation, owner mutation, checked indexing or
;: recoverable work occurs. The plane scratch is wiped after the last round.
(unsafe
  (define (cipher!
    [schedule : (Ptr u8)]
    [source : (Ptr u8)]
    [destination : (MutPtr u8)]
    [rounds : i64]) : unit
    (let
      [scratch : (Array u64 8) (make-array u64 8)]
      [state : (MutPtr u64)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)))]
      [round : i64 1]
      (unsafe
        (absorb! source state 0))
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
      (unsafe
        (squeeze! (ptr-cast state : (Ptr u64)) destination))
      (unsafe
        (secret.wipe-words! state 8)))))

;: Require exact live fixed storage, including its public capacity.
(define (check-fixed [owner : (& owner secret.SecretFixed)] [length : i64]) : secret.SecretStatus
  (cond
    [(not
        (unsafe
          (secret.storage-live? owner.handle.storage owner.handle.generation)))
      (secret.SecretErr (secret.SecretClosed))]
    [(or
        (not (= (secret.fixed-length owner) length))
        (not
          (=
            (unsafe
              (secret.live-capacity
                owner.handle.storage
                owner.handle.generation))
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
          (secret.storage-live?
            input.value.handle.storage
            input.value.handle.generation)))
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
                      (ptr-cast
                        (secret.storage-data key.handle.storage)
                        : (Ptr u8))
                      (secret.storage-data expanded.handle.storage)
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
            (secret.storage-live?
              expanded.handle.storage
              expanded.handle.generation)))
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
                        (secret.storage-data expanded.handle.storage)
                        : (Ptr u8)))]
                  [input : (Ptr u8)
                    (unsafe
                      (ptr-cast
                        (secret.storage-data source.handle.storage)
                        : (Ptr u8)))]
                  [output : (MutPtr u8)
                    (unsafe
                      (secret.storage-data destination.handle.storage))]
                  [output-read : (Ptr u8)
                    (unsafe
                      (ptr-cast output : (Ptr u8)))]
                  (if (or
                    (= source.handle.storage destination.handle.storage)
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