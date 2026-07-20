(import stdlib.math)

;; MPFR-256 vectors: curated thresholds/CORE-MATH cases
;; plus deterministic samples; count=96, seed=5227.
;; CORE-MATH revision: 66832f6d97d2245f8f10ea534ed93858e9b058dd.
(define exp-f64-inputs : (Array u64 96)
  (array
    0x0000000000000000
    0x8000000000000000
    0x0000000000000001
    0x8000000000000001
    0x3ff0000000000000
    0xbff0000000000000
    0x3fe62e42fefa39ef
    0xbfe62e42fefa39ef
    0x4080000000000000
    0xc080000000000000
    0x7fefffffffffffff
    0xffefffffffffffff
    0x40862e42fefa39ef
    0x40862e42fefa39f0
    0xc0874910d52d3052
    0xc0874910d52d3051
    0xc0874385446d71c3
    0xc0874385446d71c4
    0x3cf0000000000000
    0xbce0000000000000
    0x3ce0000000000000
    0x3cd0000000000000
    0xbcd0000000000000
    0x3cc0000000000000
    0xbcc0000000000000
    0x3cb0000000000000
    0xbcb0000000000000
    0x3ca0000000000000
    0xbca0000000000000
    0xbce0000000000001
    0x3ce0000000000001
    0xbcd0000000000001
    0x3cd0000000000001
    0xbcc0000000000001
    0x3cc0000000000001
    0x63e4eacef0cfe3fb
    0xc07727cbe92827be
    0x28b982f34fbab836
    0x4071754fbe6542d4
    0xc805f16cf5748292
    0xc06d721f11a5b088
    0x79bbfe11db903ec2
    0x4071ac12314487e8
    0xbf7e4f2546411127
    0xc0835ee4b5662c90
    0xb53eec82d7f0afba
    0x4081261969f30ca8
    0x0286144e602890b2
    0xc083d1efac4a2f07
    0x7fbc1c77fcdd27fd
    0xc06c341d4b2f2bac
    0x4497220862d5b1db
    0x4082d86657442ee6
    0xe129c1321080014f
    0x406d3b2cd7f7e4dc
    0x9faac4505a366347
    0xc071b3fe5ef4ce4c
    0x03aa58b2b6b1c09e
    0x40589ff3be63af90
    0x0836b5c40ee984a0
    0xc073e149cdb1e92a
    0x2b9462f761fb05ca
    0xc068f6c7339ff094
    0x5583e75fb709a60a
    0xc080427093b87e7c
    0x99e1b0986802430e
    0xc0365215f80a0140
    0x570a28efe68f7d13
    0xc078f95770ea7bec
    0x46d761ca2351d673
    0xc086e7de270c0564
    0x4dff4c2d2a16b59e
    0x4059b8a0843deac8
    0xf580d5006f164efd
    0xc06155eb0cf083c8
    0x11ccf0011140abcc
    0x407de68acbb56254
    0xc1e08b6764d26aae
    0xc071857a50af0fd9
    0xf76066432b532b5e
    0x4063cc445be9fd54
    0x616e811f09d60d6d
    0xc080358574b981f3
    0xfa2d7fc72ecfe15d
    0xc08044e80a3104db
    0x071b3a5e2c98264f
    0x4072e37c18c558d8
    0x2398077e173b938a
    0x40818877babadafe
    0x35f1bc49001096e4
    0x4053e9590d7f1a68
    0xe54fde9598e69b36
    0x40766a3c2e20aaec
    0x5d669c538a126d56
    0x407097466421a976
    0xad9d76f7aa7f511c))
(define exp-f64-bits : (Array u64 96)
  (array
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x4005bf0a8b145769
    0x3fd78b56362cef38
    0x4000000000000000
    0x3fe0000000000000
    0x6e19476504ba852e
    0x11c44109edb20931
    0x7ff0000000000000
    0x0000000000000000
    0x7fefffffffffff2a
    0x7ff0000000000000
    0x0000000000000000
    0x0000000000000001
    0x0000000000000001
    0x0000000000000001
    0x3ff0000000000010
    0x3feffffffffffff0
    0x3ff0000000000008
    0x3ff0000000000004
    0x3feffffffffffff8
    0x3ff0000000000002
    0x3feffffffffffffc
    0x3ff0000000000001
    0x3feffffffffffffe
    0x3ff0000000000001
    0x3fefffffffffffff
    0x3feffffffffffff0
    0x3ff0000000000008
    0x3feffffffffffff8
    0x3ff0000000000004
    0x3feffffffffffffc
    0x3ff0000000000002
    0x7ff0000000000000
    0x1e869ff408a152c0
    0x3ff0000000000000
    0x591fcc2f8703e627
    0x0000000000000000
    0x2ab1bfc82acc52c4
    0x7ff0000000000000
    0x596e738687c582ee
    0x3fefc39afb96cafa
    0x080a835e714938f6
    0x3ff0000000000000
    0x7169ef41fe7c8136
    0x3ff0000000000000
    0x06bf9b63a84beca8
    0x7ff0000000000000
    0x2b966bc04d2f5ff2
    0x7ff0000000000000
    0x765031221cb8dbc9
    0x0000000000000000
    0x5504b8ec1811791a
    0x3ff0000000000000
    0x26647ebb76f01042
    0x3ff0000000000000
    0x48d13356dbfab2e2
    0x3ff0000000000000
    0x23413ac40dc4057a
    0x3ff0000000000000
    0x2ded613a7111c650
    0x7ff0000000000000
    0x110483d150b6f1ba
    0x3ff0000000000000
    0x3debd239829d98bb
    0x7ff0000000000000
    0x1be6fb1d172395ae
    0x7ff0000000000000
    0x000000000001713b
    0x7ff0000000000000
    0x493593933b98ea4c
    0x0000000000000000
    0x336e45adf346296e
    0x3ff0000000000000
    0x6b125af6b02b9d68
    0x0000000000000000
    0x26a772fc432e0ab1
    0x0000000000000000
    0x4e369c1112091bde
    0x7ff0000000000000
    0x1129c81a1540a815
    0x0000000000000000
    0x10fe24b975a1ee89
    0x3ff0000000000000
    0x5b30171c44fea192
    0x3ff0000000000000
    0x7285a644189e4f95
    0x3ff0000000000000
    0x471df5d0f1fe8a51
    0x0000000000000000
    0x604539a636f83508
    0x7ff0000000000000
    0x57df584a5c61c914
    0x3ff0000000000000))
(define exp-f32-inputs : (Array u32 96)
  (array
    0x00000000
    0x80000000
    0x00000001
    0x80000001
    0x3f800000
    0xbf800000
    0x3f317218
    0xbf317218
    0x42b00000
    0xc2b00000
    0x42b17216
    0x42b17217
    0x42b17218
    0xc2cff1b3
    0xc2cff1b4
    0xc2cff1b5
    0x7f7fffff
    0xff7fffff
    0x33800000
    0xb3800000
    0x12b14bd9
    0x422aa07d
    0xdc024a2c
    0x40399c33
    0x04e94bb6
    0xc22e9448
    0xfeaec2ae
    0xc2053fa4
    0x47c4c257
    0x420ec184
    0x3371d21d
    0xc206c297
    0xa1f2fb4f
    0xc2976f25
    0x49e8cdca
    0x424eba63
    0x8c1fc06f
    0xbfcee43d
    0x7f784007
    0xc29817d1
    0xe91b35ba
    0x3f8c2da9
    0xfac5eb39
    0x421e5918
    0x6b308e08
    0x42b25607
    0xa0e643c2
    0xc1db22f7
    0x700ba448
    0x4258bf52
    0xf7890902
    0xc1e8931c
    0xd673fa38
    0x4292f3e6
    0x3d099894
    0xc27f80b0
    0xbb14ea0a
    0xc28341a7
    0x3456bcbe
    0xc282a2eb
    0xf3bbd3d3
    0xc271fa44
    0x8fe0b174
    0x4285b7a5
    0x5f93cfc6
    0xc2cbeb45
    0x9efaad29
    0x42ac057e
    0xdc54bbb5
    0xc298267a
    0x847c6fd4
    0x400746f1
    0x924c2f7d
    0xc2a168a6
    0xa0a414ef
    0x429f60d9
    0xfbc5a9ac
    0xc2170586
    0x375503d3
    0x4239b7e2
    0x7369f7b4
    0x419893d9
    0xe242c9bf
    0x409eb948
    0x8d1ecb92
    0x421106d5
    0xb01abf10
    0xc211c767
    0xd2d75924
    0xc22ca7c1
    0x6b460636
    0xc2190958
    0x92da5c11
    0x422671d8
    0xe1556954
    0x42281d7a))
(define exp-f32-bits : (Array u32 96)
  (array
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x402df854
    0x3ebc5ab2
    0x40000000
    0x3f000000
    0x7ef882b7
    0x0041edc4
    0x7f7fff04
    0x7f7fff84
    0x7f800000
    0x00000001
    0x00000001
    0x00000000
    0x7f800000
    0x00000000
    0x3f800001
    0x3f7fffff
    0x3f800000
    0x5e3a312f
    0x00000000
    0x41916a8e
    0x3f800000
    0x20030a0b
    0x00000000
    0x2775b20e
    0x7f800000
    0x59338f1e
    0x3f800000
    0x272860d5
    0x3f800000
    0x08d94521
    0x7f800000
    0x64bce378
    0x3f800000
    0x3e4b642a
    0x7f800000
    0x089c49dc
    0x00000000
    0x403f55cb
    0x00000000
    0x5c0a54a3
    0x7f800000
    0x7f800000
    0x3f800000
    0x2bb2b971
    0x7f800000
    0x669083f5
    0x00000000
    0x2a854541
    0x00000000
    0x74805aaa
    0x3f845f77
    0x116638fc
    0x3f7f6b41
    0x101f9e47
    0x3f800002
    0x1059a239
    0x00000000
    0x13d39357
    0x3f800000
    0x6fafaa5f
    0x7f800000
    0x00000004
    0x3f800000
    0x7d87fad8
    0x00000000
    0x0897e07f
    0x3f800000
    0x41047633
    0x3f800000
    0x053dc75c
    0x3f800000
    0x78fa3c98
    0x00000000
    0x2438e26d
    0x3f80006b
    0x60fd2063
    0x7f800000
    0x4d36f4d4
    0x00000000
    0x430e9c4c
    0x3f800000
    0x599e635f
    0x3f800000
    0x252b6ae0
    0x00000000
    0x2053fa42
    0x7f800000
    0x23df70e9
    0x3f800000
    0x5d82e46f
    0x00000000
    0x5dc6bcd0))

(define (exp-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (if (or
    (= expected (cast 0 : u64))
    (= expected (cast 0x7ff0000000000000 : u64)))
    (= actual expected)
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u64))
      (<= (- expected actual) (cast 1 : u64)))))

(define (exp-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (if (or (= expected (cast 0 : u32)) (= expected (cast 0x7f800000 : u32)))
    (= actual expected)
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u32))
      (<= (- expected actual) (cast 1 : u32)))))

(define (exp-check-f64 [index : i64]) : bool
  (exp-u64-within-one-ulp?
    (math.f64-to-bits
      (math.f64-exp (math.f64-from-bits (array-ref exp-f64-inputs index))))
    (array-ref exp-f64-bits index)))

(define (exp-check-f32 [index : i64]) : bool
  (exp-u32-within-one-ulp?
    (math.f32-to-bits
      (math.f32-exp (math.f32-from-bits (array-ref exp-f32-inputs index))))
    (array-ref exp-f32-bits index)))

(define (main) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i 96)
        (begin
          (unless (exp-check-f64 i) (return (+ 10 i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 96)
        (begin
          (unless (exp-check-f32 i) (return (+ 100010 i)))
          (set! i (+ i 1))))
      (unless
        (=
          (math.f64-to-bits (math.f64-exp (math.f64-negative-infinity)))
          (cast 0 : u64))
        (return 200001))
      (unless
        (=
          (math.f64-to-bits (math.f64-exp (math.f64-positive-infinity)))
          (cast 0x7ff0000000000000 : u64))
        (return 200002))
      (unless
        (math.f64-nan? (math.f64-exp (math.f64-quiet-nan)))
        (return 200003))
      (unless
        (=
          (math.f32-to-bits (math.f32-exp (math.f32-negative-infinity)))
          (cast 0 : u32))
        (return 200004))
      (unless
        (=
          (math.f32-to-bits (math.f32-exp (math.f32-positive-infinity)))
          (cast 0x7f800000 : u32))
        (return 200005))
      (unless
        (math.f32-nan? (math.f32-exp (math.f32-quiet-nan)))
        (return 200006))
      0)))