;; Public FIPS 197-upd1 Table 4, Appendices A/B and maintained AES core examples.
;; Pinned provenance: tests/fixtures/crypto-aes/README.md.
(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)
(import stdlib.tests.crypto_aes_core_inline as vectors)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.test)

;: Expected schedules enter opaque storage; comparisons return only pass/fail.
(define (assert-schedule
  [actual : (& actual secret.SecretBytes)]
  [text : String]) : unit
  (let
    [bytes : byte_buf.ByteBuf (vectors.public-hex text)]
    (match (secret.bytes-from-bytes
      (byte_buf.as-bytes (& bytes))
      (byte_buf.bytes-length (byte_buf.as-bytes (& bytes))))
      [(SecretBytesOk expected)
        (match (secret.bytes-equal actual (& expected))
          [(SecretCompareOk equal)
            (test.assert-true equal "complete FIPS schedule")]
          [_ (test.assert-true false "schedule length")])
        (secret.close-bytes expected)]
      [_ (test.assert-true false "expected schedule construction")])))

;: Assert a state through fixed-work opaque equality without a readable getter.
(define (assert-state [actual : (& actual secret.SecretFixed)] [text : String]) : unit
  (let
    [expected : secret.SecretFixed (vectors.fixed-hex (secret.Secret16) text)]
    (test.assert-true
      (vectors.equal-fixed? actual (& expected))
      "FIPS intermediate state")
    (secret.close-fixed expected)))

(test
  aes-fips-complete-schedule-128
  (match (aes.new-128
    (vectors.fixed-hex (secret.Secret16) "2b7e151628aed2a6abf7158809cf4f3c"))
    [(Aes128Ok schedule)
      (assert-schedule
        (& schedule.expanded)
        "2b7e151628aed2a6abf7158809cf4f3ca0fafe1788542cb123a339392a6c7605f2c295f27a96b9435935807a7359f67f3d80477d4716fe3e1e237e446d7a883bef44a541a8525b7fb671253bdb0bad00d4d1c6f87c839d87caf2b8bc11f915bc6d88a37a110b3efddbf98641ca0093fd4e54f70e5f5fc9f384a64fb24ea6dc4fead27321b58dbad2312bf5607f8d292fac7766f319fadc2128d12941575c006ed014f9a8c9ee2589e13f0cc8b6630ca6")
      (aes.close-128 schedule)]
    [_ (test.assert-true false "schedule construction")]))

(test
  aes-fips-complete-schedule-256
  (match (aes.new-256
    (vectors.fixed-hex
      (secret.Secret32)
      "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"))
    [(Aes256Ok schedule)
      (assert-schedule
        (& schedule.expanded)
        "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff49ba354118e6925afa51a8b5f2067fcdea8b09c1a93d194cdbe49846eb75d5b9ad59aecb85bf3c917fee94248de8ebe96b5a9328a2678a647983122292f6c79b3812c81addadf48ba24360af2fab8b46498c5bfc9bebd198e268c3ba709e0421468007bacb2df331696e939e46c518d80c814e20476a9fb8a5025c02d59c58239de1369676ccc5a71fa2563959674ee155886ca5d2e2f31d77e0af1fa27cf73c3749c47ab18501ddae2757e4f7401905acafaaae3e4d59b349adf6acebd10190dfe4890d1e6188d0b046df344706c631e")
      (aes.close-256 schedule)]
    [_ (test.assert-true false "schedule construction")]))

(test
  aes-sbox-all-public-bytes
  (let
    [oracle : byte_buf.ByteBuf
      (vectors.public-hex
        "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16")]
    [index : i64 0]
    (while (< index 256)
      (test.assert-true
        (=
          (aes.sbox (cast index : u8))
          (byte_buf.bytes-ref (byte_buf.as-bytes (& oracle)) index))
        "FIPS Table 4")
      (set! index (+ index 1)))))

(test
  aes-fips-appendix-b-states
  (match (aes.new-128
    (vectors.fixed-hex (secret.Secret16) "2b7e151628aed2a6abf7158809cf4f3c"))
    [(Aes128Ok schedule)
      (let
        [state : secret.SecretFixed
          (vectors.fixed-hex
            (secret.Secret16)
            "3243f6a8885a308d313198a2e0370734")]
        [expected : (Array String 40)
          (array
            "193de3bea0f4e22b9ac68d2ae9f84808"
            "d42711aee0bf98f1b8b45de51e415230"
            "d4bf5d30e0b452aeb84111f11e2798e5"
            "046681e5e0cb199a48f8d37a2806264c"
            "a49c7ff2689f352b6b5bea43026a5049"
            "49ded28945db96f17f39871a7702533b"
            "49db873b453953897f02d2f177de961a"
            "584dcaf11b4b5aacdbe7caa81b6bb0e5"
            "aa8f5f0361dde3ef82d24ad26832469a"
            "ac73cf7befc111df13b5d6b545235ab8"
            "acc1d6b8efb55a7b1323cfdf457311b5"
            "75ec0993200b633353c0cf7cbb25d0dc"
            "486c4eee671d9d0d4de3b138d65f58e7"
            "52502f2885a45ed7e311c807f6cf6a94"
            "52a4c89485116a28e3cf2fd7f6505e07"
            "0fd6daa9603138bf6fc0106b5eb31301"
            "e0927fe8c86363c0d9b1355085b8be01"
            "e14fd29be8fbfbba35c89653976cae7c"
            "e1fb967ce8c8ae9b356cd2ba974ffb53"
            "25d1a9adbd11d168b63a338e4c4cc0b0"
            "f1006f55c1924cef7cc88b325db5d50c"
            "a163a8fc784f29df10e83d234cd503fe"
            "a14f3dfe78e803fc10d5a8df4c632923"
            "4b868d6d2c4a8980339df4e837d218d8"
            "260e2e173d41b77de86472a9fdd28b25"
            "f7ab31f02783a9ff9b4340d354b53d3f"
            "f783403f27433df09bb531ff54aba9d3"
            "1415b5bf461615ec274656d7342ad843"
            "5a4142b11949dc1fa3e019657a8c040c"
            "be832cc8d43b86c00ae1d44dda64f2fe"
            "be3bd4fed4e1f2c80a642cc0da83864d"
            "00512fd1b1c889ff54766dcdfa1b99ea"
            "ea835cf00445332d655d98ad8596b0c5"
            "87ec4a8cf26ec3d84d4c46959790e7a6"
            "876e46a6f24ce78c4d904ad897ecc395"
            "473794ed40d4e4a5a3703aa64c9f42bc"
            "eb40f21e592e38848ba113e71bc342d2"
            "e9098972cb31075f3d327d94af2e2cb5"
            "e9317db5cb322c723d2e895faf090794"
            "3925841d02dc09fbdc118597196a0b32")]
        [data : (MutPtr u8)
          (unsafe
            (secret.storage-data state.handle.storage))]
        [keys : (Ptr u8)
          (unsafe
            (ptr-cast
              (secret.storage-data schedule.expanded.handle.storage)
              : (Ptr u8)))]
        [round : i64 1]
        (unsafe
          (aes.add-round-key! data keys 0))
        (while (<= round 10)
          (let
            [offset : i64 (* (- round 1) 4)]
            (assert-state
              (& state)
              (string.copy (& (array-ref expected offset))))
            (unsafe
              (aes.sub-bytes! data))
            (assert-state
              (& state)
              (string.copy (& (array-ref expected (+ offset 1)))))
            (unsafe
              (aes.shift-rows! data))
            (assert-state
              (& state)
              (string.copy (& (array-ref expected (+ offset 2)))))
            (when
              (< round 10)
              (unsafe
                (aes.mix-columns! data))
              (assert-state
                (& state)
                (string.copy (& (array-ref expected (+ offset 3))))))
            (unsafe
              (aes.add-round-key! data keys round)))
          (set! round (+ round 1)))
        (assert-state (& state) (string.copy (& (array-ref expected 39))))
        (secret.close-fixed state))
      (aes.close-128 schedule)]
    [_ (test.assert-true false "schedule construction")]))

(test
  aes-maintained-core-examples
  (begin
    (vectors.vector
      false
      "2b7e151628aed2a6abf7158809cf4f3c"
      "6bc1bee22e409f96e93d7e117393172a"
      "3ad77bb40d7a3660a89ecaf32466ef97")
    (vectors.vector
      false
      "2b7e151628aed2a6abf7158809cf4f3c"
      "ae2d8a571e03ac9c9eb76fac45af8e51"
      "f5d3d58503b9699de785895a96fdbaaf")
    (vectors.vector
      false
      "2b7e151628aed2a6abf7158809cf4f3c"
      "30c81c46a35ce411e5fbc1191a0a52ef"
      "43b1cd7f598ece23881b00e3ed030688")
    (vectors.vector
      false
      "2b7e151628aed2a6abf7158809cf4f3c"
      "f69f2445df4f9b17ad2b417be66c3710"
      "7b0c785e27e8ad3f8223207104725dd4")
    (vectors.vector
      true
      "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
      "6bc1bee22e409f96e93d7e117393172a"
      "f3eed1bdb5d2a03c064b5a7e3db181f8")
    (vectors.vector
      true
      "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
      "ae2d8a571e03ac9c9eb76fac45af8e51"
      "591ccb10d410ed26dc5ba74a31362870")
    (vectors.vector
      true
      "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
      "30c81c46a35ce411e5fbc1191a0a52ef"
      "b6ed21b99ca6f4f9f153e7b1beafed1d")
    (vectors.vector
      true
      "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
      "f69f2445df4f9b17ad2b417be66c3710"
      "23304b7a39f9f3ff067d8d8f9e24ecc7")))