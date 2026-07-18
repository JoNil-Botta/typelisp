(import stdlib.math)

;; Correctly rounded reference bits generated with MPFR at 256-bit working
;; precision in round-to-nearest mode. The implementation contract is at most
;; 1.5 ULP, so every finite result must be either the correctly rounded value
;; or its immediate representable neighbor. Regenerate or independently verify
;; the stored results with scripts/generate-math-trig-vectors.py.
(define trig-f64-inputs : (Array u64 59)
  (array
    0x0000000000000000
    0x8000000000000000
    0x0000000000000001
    0x8000000000000001
    0x3e4fffffffffffff
    0x3e50000000000000
    0x3ff0000000000000
    0xbff0000000000000
    0x3fe921fb54442d17
    0x3fe921fb54442d18
    0x3fe921fb54442d19
    0x3ff921fb54442d17
    0x3ff921fb54442d18
    0x3ff921fb54442d19
    0x400921fb54442d17
    0x400921fb54442d18
    0x400921fb54442d19
    0x4012d97c7f3321d2
    0x4024000000000000
    0xc024000000000000
    0x412e848000000000
    0xc12e848000000000
    0x413921faffffffff
    0x413921fb00000000
    0x413921fbffffffff
    0x41d0000000000000
    0xc1d0000000000000
    0x4310000000000000
    0x4630000000000000
    0x5f30000000000000
    0x7e70000000000000
    0x7fe0000000000000
    0x7fefffffffffffff
    0xffefffffffffffff
    0x001aee21bf46bc00
    0x80a0754d1a1a8d4f
    0x8644904a6d278932
    0x92c9cf4276846d19
    0x1f4b2fd56a5b15b4
    0x2bc815deeaf29df3
    0xb84e100db2d7d206
    0x3fe9e6a57e06665d
    0x3ff902917b70a2a8
    0x4b001baf16ad70d7
    0xddcaa7c38002001a
    0x7085db213cf06be1
    0x7fe8c014892416dc
    ;; Published hard-to-round and argument-reduction worst cases from the
    ;; CORE-MATH binary64 sin/cos/tan `.wc` corpora.
    0x400005023d32fee5
    0x3f200874a5f9fc33
    0x3f30009effd4beda
    0x3ff00147eec5cfa5
    0x3f40004b89dcb553
    0x3f200452f0e0134d
    0x7fe61a3db8c8d129
    0x7fd4551061aadd5d
    0x40507e4cef4cbd98
    0x402f6a7a2955385e
    0x3e57137449123ef6
    0x3e57137449123ef7))
(define trig-f64-sin-bits : (Array u64 59)
  (array
    0x0000000000000000
    0x8000000000000000
    0x0000000000000001
    0x8000000000000001
    0x3e4fffffffffffff
    0x3e50000000000000
    0x3feaed548f090cee
    0xbfeaed548f090cee
    0x3fe6a09e667f3bcc
    0x3fe6a09e667f3bcc
    0x3fe6a09e667f3bcd
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3cc469898cc51702
    0x3ca1a62633145c07
    0xbcb72cece675d1fd
    0xbff0000000000000
    0xbfe1689ef5f34f52
    0x3fe1689ef5f34f52
    0xbfd6664b2568d867
    0x3fd6664b2568d867
    0xbfd4b02e5c25af00
    0xbfd4b02e5be91e9e
    0x3fe3e479a5ff2619
    0xbfe3c12353728caf
    0x3fe3c12353728caf
    0x3fdfc4f5e3aaeddb
    0xbfebe8ed97ac1f59
    0x3fdb78f3ff6b537b
    0xbfc460b8ae1c886e
    0x3fe205248cbdb760
    0x3f7452fc98b34e97
    0xbf7452fc98b34e97
    0x001aee21bf46bc00
    0x80a0754d1a1a8d4f
    0x8644904a6d278932
    0x92c9cf4276846d19
    0x1f4b2fd56a5b15b4
    0x2bc815deeaf29df3
    0xb84e100db2d7d206
    0x3fe729ffca4af610
    0x3fefffc2532f62bf
    0x3fd849a2858b84c6
    0xbfe75d3067b7224b
    0xbfef43680dc09e31
    0x3fe8cbb2c2d233be
    0x3fed109ad145c88f
    0x3f200874a54e4265
    0x3f30009efd29c4ac
    0x3feaeeb6d68887a5
    0x3f40004b7f317394
    0x3f200452f034de1f
    0xbc7dd15f96b823f2
    0x3cdb137a7a07431b
    0xbcd1abdbb9ea8e6e
    0x3cc60fafbfd97309
    0x3e57137449123ef6
    0x3e57137449123ef6))
(define trig-f64-cos-bits : (Array u64 59)
  (array
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3fefffffffffffff
    0x3fefffffffffffff
    0x3fe14a280fb5068c
    0x3fe14a280fb5068c
    0x3fe6a09e667f3bcd
    0x3fe6a09e667f3bcd
    0x3fe6a09e667f3bcc
    0x3cb469898cc51702
    0x3c91a62633145c07
    0xbca72cece675d1fd
    0xbff0000000000000
    0xbff0000000000000
    0xbff0000000000000
    0xbcaa79394c9e8a0a
    0xbfead9ac890c6b1f
    0xbfead9ac890c6b1f
    0x3fedf9df9906d32c
    0x3fedf9df9906d32c
    0x3fee483125700ac3
    0x3fee4831257a62da
    0x3fe910d18d3aa54e
    0x3fe92cb46a920144
    0x3fe92cb46a920144
    0x3febc7711009e00b
    0x3fdf4eb3ff66e36d
    0x3fece6de5cd1db81
    0x3fef9785160c8815
    0xbfea719f26c232bf
    0xbfefffe62ecfab75
    0xbfefffe62ecfab75
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3fe613e66708b1c4
    0x3f7f69c4a50ed4be
    0x3fed9b3097910e37
    0x3fe5ddb31b03dd06
    0x3fcb4eadac34053f
    0xbfe43a6090859abf
    0xbfdac6909aedad7b
    0x3feffffffbfbc48f
    0x3fefffffeffec1fc
    0x3fe148001d3ec044
    0x3fefffffbffda3c1
    0x3feffffffbfdd63d
    0x3ff0000000000000
    0x3ff0000000000000
    0xbff0000000000000
    0xbff0000000000000
    0x3feffffffffffffe
    0x3feffffffffffffe))
(define trig-f64-tan-bits : (Array u64 59)
  (array
    0x0000000000000000
    0x8000000000000000
    0x0000000000000001
    0x8000000000000001
    0x3e50000000000000
    0x3e50000000000000
    0x3ff8eb245cbee3a6
    0xbff8eb245cbee3a6
    0x3feffffffffffffd
    0x3fefffffffffffff
    0x3ff0000000000001
    0x4329153d9443ed0b
    0x434d02967c31cdb5
    0xc33617a15494767a
    0xbcc469898cc51702
    0xbca1a62633145c07
    0x3cb72cece675d1fd
    0x4333570efd768923
    0x3fe4bf5f34be3782
    0xbfe4bf5f34be3782
    0xbfd7e9768ab734c0
    0x3fd7e9768ab734c0
    0xbfd5dca6bd5e8435
    0xbfd5dca6bd170c6f
    0x3fe9654894a13da8
    0xbfe91c3c126f9d13
    0x3fe91c3c126f9d13
    0x3fe24c5e153a88ae
    0xbffc86fbfa8cecc3
    0x3fde6adc16cfc532
    0xbfc4a41d560c08cc
    0xbfe5ce6b4c0d02a3
    0xbf74530cfe729484
    0x3f74530cfe729484
    0x001aee21bf46bc00
    0x80a0754d1a1a8d4f
    0x8644904a6d278932
    0x92c9cf4276846d19
    0x1f4b2fd56a5b15b4
    0x2bc815deeaf29df3
    0xb84e100db2d7d206
    0x3ff0c98ab4975308
    0x40604c65808f2853
    0x3fda405b8195f3d9
    0xbff1189c43e43285
    0xc012516179c3f1ca
    0xbff39ce94545fd8c
    0xc0015e315c9f3763
    0x3f200874a7516fd0
    0x3f30009f052ab337
    0x3ff8ef883fd7ccf4
    0x3f40004b9f3338f8
    0x3f200452f2367da9
    0xbc7dd15f96b823f2
    0x3cdb137a7a07431b
    0x3cd1abdbb9ea8e6e
    0xbcc60fafbfd97309
    0x3e57137449123ef7
    0x3e57137449123ef8))
(define trig-f32-inputs : (Array u32 45)
  (array
    0x00000000
    0x80000000
    0x00000001
    0x80000001
    0x397fffff
    0x39800000
    0x3f800000
    0xbf800000
    0x3f490fda
    0x3f490fdb
    0x3fc90fda
    0x3fc90fdb
    0x3fc90fdc
    0x40490fda
    0x40490fdb
    0x40490fdc
    0x4096cbe4
    0x41200000
    0xc1200000
    0x49742400
    0xc9742400
    0x4dc90fda
    0x4dc90fdb
    0x4dc90fdc
    0x4f000000
    0xcf000000
    0x5f000000
    0x7e800000
    0x7f000000
    0x7f7fffff
    0xff7fffff
    0x8081dcce
    0x029f3dd5
    0x8a74f530
    0x944086cf
    0x1e2345e2
    0xa8238bd9
    0xb2268364
    0x3c017773
    0xbf54d636
    0xbfdd581d
    0xcb1cfad8
    0xe471c057
    0xfd5761ca
    0xff0f66a1))
(define trig-f32-sin-bits : (Array u32 45)
  (array
    0x00000000
    0x80000000
    0x00000001
    0x80000001
    0x397fffff
    0x39800000
    0x3f576aa4
    0xbf576aa4
    0x3f3504f3
    0x3f3504f3
    0x3f800000
    0x3f800000
    0x3f800000
    0x34222169
    0xb3bbbd2e
    0xb4aeef4c
    0xbf800000
    0xbf0b44f8
    0x3f0b44f8
    0xbeb33259
    0x3eb33259
    0xbf7cf804
    0xbf3d5f98
    0xbe7bf669
    0xbf78a7c9
    0x3f78a7c9
    0x3f7ffb70
    0x3ea91216
    0x3f1f9631
    0xbf0599b3
    0x3f0599b3
    0x8081dcce
    0x029f3dd5
    0x8a74f530
    0x944086cf
    0x1e2345e2
    0xa8238bd9
    0xb2268364
    0x3c01771b
    0xbf3d26a9
    0xbf7ccafb
    0xbf69fa2b
    0xbebd3260
    0xbd8e4766
    0xbf5e14a4))
(define trig-f32-cos-bits : (Array u32 45)
  (array
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f0a5140
    0x3f0a5140
    0x3f3504f4
    0x3f3504f3
    0x33a22169
    0xb33bbd2e
    0xb42eef4c
    0xbf800000
    0xbf800000
    0xbf800000
    0x324cde2e
    0xbf56cd64
    0xbf56cd64
    0x3f6fcefd
    0x3f6fcefd
    0x3e1d1cf0
    0x3f2c42b6
    0x3f78211e
    0x3e738617
    0x3e738617
    0x3c41551c
    0x3f71a3c8
    0x3f482b8f
    0x3f5a5f96
    0x3f5a5f96
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f800000
    0x3f7ffdf4
    0x3f2c8138
    0xbe219478
    0xbecfc199
    0x3f6de16a
    0x3f7f61a8
    0xbefeaf88))
(define trig-f32-tan-bits : (Array u32 45)
  (array
    0x00000000
    0x80000000
    0x00000001
    0x80000001
    0x397fffff
    0x39800000
    0x3fc75923
    0xbfc75923
    0x3f7fffff
    0x3f800000
    0x4b4a1bda
    0xcbae8a4a
    0xcabb50c8
    0xb4222169
    0x33bbbd2e
    0x34aeef4c
    0xcc9ff26d
    0x3f25fafa
    0xbf25fafa
    0xbebf4bb4
    0x3ebf4bb4
    0xc0ce17fd
    0xbf8cb742
    0xbe81fa36
    0xc082b280
    0x4082b280
    0x42a97a87
    0x3eb31e44
    0x3f4c18eb
    0xbf1c9eca
    0x3f1c9eca
    0x8081dcce
    0x029f3dd5
    0x8a74f530
    0x944086cf
    0x1e2345e2
    0xa8238bd9
    0xb2268364
    0x3c017824
    0xbf8c5a07
    0x40c841c0
    0x401027a9
    0xbecb9ba5
    0xbd8e9f9e
    0x3fdf3a08))

(define (trig-ordered-u64 [bits : u64]) : u64
  (if (!= (bit-and bits (cast 0x8000000000000000 : u64)) (cast 0 : u64))
    (bit-xor bits (cast 0xffffffffffffffff : u64))
    (bit-or bits (cast 0x8000000000000000 : u64))))

(define (trig-ordered-u32 [bits : u32]) : u32
  (if (!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))
    (bit-xor bits (cast 0xffffffff : u32))
    (bit-or bits (cast 0x80000000 : u32))))

(define (trig-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (let
    [a : u64 (trig-ordered-u64 actual)]
    [b : u64 (trig-ordered-u64 expected)]
    (if (> a b)
      (<= (- a b) (cast 1 : u64))
      (<= (- b a) (cast 1 : u64)))))

(define (trig-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (let
    [a : u32 (trig-ordered-u32 actual)]
    [b : u32 (trig-ordered-u32 expected)]
    (if (> a b)
      (<= (- a b) (cast 1 : u32))
      (<= (- b a) (cast 1 : u32)))))

(define (trig-check-f64 [index : i64]) : bool
  (let
    [value : f64 (math.f64-from-bits (array-ref trig-f64-inputs index))]
    (and
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-sin value))
        (array-ref trig-f64-sin-bits index))
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-cos value))
        (array-ref trig-f64-cos-bits index))
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-tan value))
        (array-ref trig-f64-tan-bits index)))))

(define (trig-check-f32 [index : i64]) : bool
  (let
    [value : f32 (math.f32-from-bits (array-ref trig-f32-inputs index))]
    (and
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-sin value))
        (array-ref trig-f32-sin-bits index))
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-cos value))
        (array-ref trig-f32-cos-bits index))
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-tan value))
        (array-ref trig-f32-tan-bits index)))))

(define (main) : i64
  (let
    [i : i64 0]
    [negative-zero64 : f64 (math.f64-from-bits 0x8000000000000000)]
    [negative-zero32 : f32 (math.f32-from-bits (cast 0x80000000 : u32))]
    (begin
      (while (< i 59)
        (begin
          (unless (trig-check-f64 i) (return (+ 10 i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 45)
        (begin
          (unless (trig-check-f32 i) (return (+ 100 i)))
          (set! i (+ i 1))))
      (unless
        (= (math.f64-to-bits (math.f64-sin negative-zero64)) 0x8000000000000000)
        (return 201))
      (unless
        (= (math.f64-to-bits (math.f64-tan negative-zero64)) 0x8000000000000000)
        (return 202))
      (unless
        (= (math.f64-to-bits (math.f64-cos negative-zero64)) 0x3ff0000000000000)
        (return 203))
      (unless
        (=
          (math.f32-to-bits (math.f32-sin negative-zero32))
          (cast 0x80000000 : u32))
        (return 204))
      (unless
        (=
          (math.f32-to-bits (math.f32-tan negative-zero32))
          (cast 0x80000000 : u32))
        (return 205))
      (unless
        (=
          (math.f32-to-bits (math.f32-cos negative-zero32))
          (cast 0x3f800000 : u32))
        (return 206))
      (if (and
        (math.f64-nan? (math.f64-sin (math.f64-positive-infinity)))
        (math.f64-nan? (math.f64-cos (math.f64-negative-infinity)))
        (math.f64-nan? (math.f64-tan (math.f64-quiet-nan)))
        (math.f32-nan? (math.f32-sin (math.f32-positive-infinity)))
        (math.f32-nan? (math.f32-cos (math.f32-negative-infinity)))
        (math.f32-nan? (math.f32-tan (math.f32-quiet-nan))))
        0
        207))))