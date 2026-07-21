(import stdlib.math)

;; MPFR-256 round-to-nearest vectors: neighbors around one, powers of two,
;; normal/subnormal extrema, musl table boundaries, deterministic broad
;; samples, and binary64 hard-to-round cases from CORE-MATH log.wc.
;; CORE-MATH revision: 66832f6d97d2245f8f10ea534ed93858e9b058dd.
(define log-f64-inputs : (Array u64 96)
  (array
    0x0000000000000001
    0x000fffffffffffff
    0x0010000000000000
    0x3ca0000000000000
    0x3cb0000000000000
    0x3cc0000000000000
    0x3fd0000000000000
    0x3fe0000000000000
    0x3feffffffffffffe
    0x3fefffffffffffff
    0x3ff0000000000000
    0x3ff0000000000001
    0x3ff0000000000002
    0x4000000000000000
    0x4010000000000000
    0x4090000000000000
    0x7fefffffffffffff
    0x3ffa6ae5142326b5
    0x3ffa6ba95b1520f9
    0x3ffa702b2ce91b30
    0x3ffa775c6c1d8d3e
    0x3ffb072ab04ee9bf
    0x3ffc877cba59d0ac
    0x3ffbbfff9457d5c3
    0x3ffbdfbc244c2cfe
    0x3ffbefeb75414206
    0x3ffc19bdd1656c31
    0x3ffc9f6ad292698f
    0x3ffb188600086fee
    0x3ffca3665f2edf3d
    0x3ffd2e75daa7d786
    0x3ffc47c00242ae49
    0x4001e852e6951306
    0x3fe5ffffffffffff
    0x3fe6000000000000
    0x3fe6000000000001
    0x3fe6ffffffffffff
    0x3fe7000000000000
    0x3fe7000000000001
    0x3fe7ffffffffffff
    0x3fe8000000000000
    0x3fe8000000000001
    0x3fe8ffffffffffff
    0x3fe9000000000000
    0x3fe9000000000001
    0x3fe9ffffffffffff
    0x3fea000000000000
    0x3fea000000000001
    0x3feaffffffffffff
    0x3feb000000000000
    0x3feb000000000001
    0x3febffffffffffff
    0x3fec000000000000
    0x3fec000000000001
    0x3fecffffffffffff
    0x3fed000000000000
    0x3fed000000000001
    0x3fedffffffffffff
    0x3fee000000000000
    0x3fee000000000001
    0x3feeffffffffffff
    0x3fef000000000000
    0x3fef000000000001
    0x3ff0ffffffffffff
    0x3ff1000000000000
    0x3ff1000000000001
    0x3ff1ffffffffffff
    0x3ff2000000000000
    0x3ff2000000000001
    0x3ff2ffffffffffff
    0x3ff3000000000000
    0x3ff3000000000001
    0x3ff3ffffffffffff
    0x3ff4000000000000
    0x3ff4000000000001
    0x3ff4ffffffffffff
    0x3ff5000000000000
    0x3ff5000000000001
    0x3ff5ffffffffffff
    0x3ff6000000000000
    0x3ff6000000000001
    0x6144132b91c0ec9e
    0x6e6eff78bd079ad3
    0x276142ee74fbe94e
    0x11de1e8ed7261268
    0x666a812b20860ce2
    0x05583f1c7e7416c7
    0x64c9d14a97a554f8
    0x36e0318790a7f082
    0x2dd43023e693b03c
    0x3b68d29c9a2b9438
    0x5194da52e14f3fde
    0x507860d2117a12bd
    0x35639c183e4c3363
    0x79ea98b00abfe05e
    0x272569392d2909c8))
(define log-f64-bits : (Array u64 96)
  (array
    0xc0874385446d71c3
    0xc086232bdd7abcd2
    0xc086232bdd7abcd2
    0xc0425e4f7b2737fa
    0xc04205966f2b4f12
    0xc041acdd632f662b
    0xbff62e42fefa39ef
    0xbfe62e42fefa39ef
    0xbcb0000000000001
    0xbca0000000000000
    0x0000000000000000
    0x3cafffffffffffff
    0x3cbffffffffffffe
    0x3fe62e42fefa39ef
    0x3ff62e42fefa39ef
    0x401bb9d3beb8c86b
    0x40862e42fefa39ef
    0x3fe00bcc31ebded7
    0x3fe00cb9ef6145e1
    0x3fe0122ef37212eb
    0x3fe01ae25c609a38
    0x3fe0c6f035e6797f
    0x3fe281c515a0a3db
    0x3fe19ee63842b127
    0x3fe1c36a38ab4c0a
    0x3fe1d5f976ee4265
    0x3fe205bd19496e54
    0x3fe29c9138f38434
    0x3fe0db7650ce23fe
    0x3fe2a104c2f6e548
    0x3fe33af28ea06979
    0x3fe239f703242df4
    0x3fe9c8f0dc2695d4
    0xbfd7fafa3bd8151f
    0xbfd7fafa3bd8151c
    0xbfd7fafa3bd81519
    0xbfd522ae0738a3db
    0xbfd522ae0738a3d8
    0xbfd522ae0738a3d5
    0xbfd269621134db95
    0xbfd269621134db92
    0xbfd269621134db90
    0xbfcf991c6cb3b37f
    0xbfcf991c6cb3b379
    0xbfcf991c6cb3b374
    0xbfca93ed3c8ad9e8
    0xbfca93ed3c8ad9e3
    0xbfca93ed3c8ad9df
    0xbfc5bf406b543db7
    0xbfc5bf406b543db2
    0xbfc5bf406b543dad
    0xbfc1178e8227e480
    0xbfc1178e8227e47c
    0xbfc1178e8227e477
    0xbfb9335e5d594992
    0xbfb9335e5d594989
    0xbfb9335e5d594980
    0xbfb08598b59e3a0f
    0xbfb08598b59e3a07
    0xbfb08598b59e39fe
    0xbfa0415d89e74455
    0xbfa0415d89e74444
    0xbfa0415d89e74434
    0x3faf0a30c0116288
    0x3faf0a30c01162a6
    0x3faf0a30c01162c4
    0x3fbe27076e2af2d8
    0x3fbe27076e2af2e6
    0x3fbe27076e2af2f4
    0x3fc5ff3070a793cd
    0x3fc5ff3070a793d4
    0x3fc5ff3070a793db
    0x3fcc8ff7c79a9a1b
    0x3fcc8ff7c79a9a22
    0x3fcc8ff7c79a9a28
    0x3fd1675cababa60b
    0x3fd1675cababa60e
    0x3fd1675cababa611
    0x3fd4618bc21c5ec0
    0x3fd4618bc21c5ec2
    0x3fd4618bc21c5ec5
    0x40771aca0c21bed0
    0x40801d5b84e35c49
    0xc071054b976557b3
    0xc07fee8f85ab54c6
    0x407aaca4d72f4a23
    0xc0844e0d0c0bf7ab
    0x40798bdfddd274ef
    0xc0591fa2f6c75406
    0xc06918f73cc724f9
    0xc049148db28c1c81
    0x4068776fde23ecae
    0x4066ed2ebf4eb7f2
    0xc05d3c0f543557b2
    0x40841871eb75c87b
    0xc0712e35b63ecc17))
(define log-f32-inputs : (Array u32 96)
  (array
    0x00000001
    0x007fffff
    0x00800000
    0x33000000
    0x3d800000
    0x3f000000
    0x3f7ffffe
    0x3f7fffff
    0x3f800000
    0x3f800001
    0x3f800002
    0x40000000
    0x40800000
    0x7f7fffff
    0x3f32ffff
    0x3f330000
    0x3f330001
    0x3f3affff
    0x3f3b0000
    0x3f3b0001
    0x3f42ffff
    0x3f430000
    0x3f430001
    0x3f4affff
    0x3f4b0000
    0x3f4b0001
    0x3f52ffff
    0x3f530000
    0x3f530001
    0x3f5affff
    0x3f5b0000
    0x3f5b0001
    0x3f62ffff
    0x3f630000
    0x3f630001
    0x3f6affff
    0x3f6b0000
    0x3f6b0001
    0x3f72ffff
    0x3f730000
    0x3f730001
    0x3f7affff
    0x3f7b0000
    0x3f7b0001
    0x3f82ffff
    0x3f830000
    0x3f830001
    0x3f8affff
    0x3f8b0000
    0x3f8b0001
    0x3f92ffff
    0x3f930000
    0x3f930001
    0x3f9affff
    0x3f9b0000
    0x3f9b0001
    0x3fa2ffff
    0x3fa30000
    0x3fa30001
    0x3faaffff
    0x3fab0000
    0x3fab0001
    0x3fb2ffff
    0x3fb30000
    0x3fb30001
    0x7f546c57
    0x42d6f21c
    0x5c6b0662
    0x2b77f6c2
    0x26bd7c3d
    0x66d579cd
    0x126e3138
    0x27365a3b
    0x5034dc9a
    0x6220a38f
    0x6d5b73d7
    0x2b685031
    0x11fabaca
    0x349ca409
    0x0a6078ad
    0x2512b333
    0x3c521775
    0x166ed806
    0x56fa578e
    0x04b61fa5
    0x75da2d27
    0x31979c8c
    0x4a3a62c6
    0x28bbba2f
    0x1dfeee6c
    0x3ccb6af4
    0x0d1e4492
    0x20f7d696
    0x10ec24be
    0x53bb9369
    0x3e68dc77))
(define log-f32-bits : (Array u32 96)
  (array
    0xc2ce8ed0
    0xc2aeac50
    0xc2aeac50
    0xc18aa123
    0xc0317218
    0xbf317218
    0xb4000001
    0xb3800000
    0x00000000
    0x33ffffff
    0x347ffffe
    0x3f317218
    0x3fb17218
    0x42b17218
    0xbeb7307a
    0xbeb73077
    0xbeb73074
    0xbea0cda4
    0xbea0cda1
    0xbea0cd9e
    0xbe8b5ae9
    0xbe8b5ae6
    0xbe8b5ae4
    0xbe6d89f3
    0xbe6d89ee
    0xbe6d89e8
    0xbe45f584
    0xbe45f57f
    0xbe45f57a
    0xbe1fda32
    0xbe1fda2d
    0xbe1fda28
    0xbdf639d5
    0xbdf639cc
    0xbdf639c3
    0xbdaf4adb
    0xbdaf4ad2
    0xbdaf4aca
    0xbd5577a7
    0xbd557797
    0xbd557786
    0xbca1956a
    0xbca19549
    0xbca19529
    0x3cbdc89a
    0x3cbdc8d8
    0x3cbdc917
    0x3da8d82b
    0x3da8d83a
    0x3da8d849
    0x3e0db950
    0x3e0db957
    0x3e0db95e
    0x3e43fcfd
    0x3e43fd03
    0x3e43fd0a
    0x3e778568
    0x3e77856e
    0x3e778575
    0x3e944ace
    0x3e944ad1
    0x3e944ad4
    0x3eabb3b6
    0x3eabb3b9
    0x3eabb3bc
    0x42b1128e
    0x4095abf0
    0x422077dc
    0xc1de0ff0
    0xc2090f71
    0x425a4ed2
    0xc279d246
    0xc20670f3
    0x41b9c1a8
    0x42403796
    0x427e7645
    0xc1de9575
    0xc27c6387
    0xc170c1cb
    0xc29335c7
    0xc21266da
    0xc08b6896
    0xc263a137
    0x420238e7
    0xc2a2e09f
    0x4296c94d
    0xc199e920
    0x416ee8fa
    0xc1fc03b5
    0xc239c7ba
    0xc06c858e
    0xc28b975a
    0xc22941ed
    0xc281163c
    0x41e0dd44
    0xbfbd925e))

(define (log-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (if (= actual expected)
    true
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u64))
      (<= (- expected actual) (cast 1 : u64)))))

(define (log-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (if (= actual expected)
    true
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u32))
      (<= (- expected actual) (cast 1 : u32)))))

(define (log-check-f64 [index : i64]) : bool
  (log-u64-within-one-ulp?
    (math.f64-to-bits
      (math.f64-log (math.f64-from-bits (array-ref log-f64-inputs index))))
    (array-ref log-f64-bits index)))

(define (log-check-f32 [index : i64]) : bool
  (log-u32-within-one-ulp?
    (math.f32-to-bits
      (math.f32-log (math.f32-from-bits (array-ref log-f32-inputs index))))
    (array-ref log-f32-bits index)))

(define (main) : i64
  (let
    [i : i64 0]
    [negative-zero64 : f64 (math.f64-from-bits 0x8000000000000000)]
    [negative-zero32 : f32 (math.f32-from-bits (cast 0x80000000 : u32))]
    (begin
      (while (< i 96)
        (begin
          (unless (log-check-f64 i) (return (+ 10 i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 96)
        (begin
          (unless (log-check-f32 i) (return (+ 100010 i)))
          (set! i (+ i 1))))
      (unless
        (and
          (= (math.f64-to-bits (math.f64-log 0.0)) 0xfff0000000000000)
          (=
            (math.f64-to-bits (math.f64-log negative-zero64))
            0xfff0000000000000)
          (=
            (math.f32-to-bits (math.f32-log (cast 0.0 : f32)))
            (cast 0xff800000 : u32))
          (=
            (math.f32-to-bits (math.f32-log negative-zero32))
            (cast 0xff800000 : u32)))
        (return 200001))
      (unless
        (and
          (= (math.f64-to-bits (math.f64-log 1.0)) (cast 0 : u64))
          (= (math.f32-to-bits (math.f32-log (cast 1.0 : f32))) (cast 0 : u32)))
        (return 200002))
      (unless
        (and
          (=
            (math.f64-to-bits (math.f64-log (math.f64-positive-infinity)))
            0x7ff0000000000000)
          (=
            (math.f32-to-bits (math.f32-log (math.f32-positive-infinity)))
            (cast 0x7f800000 : u32)))
        (return 200003))
      (unless
        (and
          (math.f64-nan? (math.f64-log -1.0))
          (math.f64-nan? (math.f64-log (math.f64-negative-infinity)))
          (math.f64-nan? (math.f64-log (math.f64-quiet-nan)))
          (math.f32-nan? (math.f32-log (cast -1.0 : f32)))
          (math.f32-nan? (math.f32-log (math.f32-negative-infinity)))
          (math.f32-nan? (math.f32-log (math.f32-quiet-nan))))
        (return 200004))
      0)))