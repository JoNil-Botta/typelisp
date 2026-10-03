;; TLS 1.3 wire codec checks (#6991). The fixed vectors are RFC 8448's traces,
;; produced by an independent implementation: every one must decode to the
;; fields noted here and re-encode to the same bytes, so the encoder and
;; decoder cannot agree on a mistake unnoticed. The rest feeds every byte
;; split, fragmentation and malformed variant through the readers and
;; decoders and checks the exact error code, offset and alert.
(import stdlib.byte_buf)
(import stdlib.net.tls_wire as tls)
(import stdlib.profile)
(import stdlib.test)

(define (hex-nibble [code : i64]) : i64
  (cond
    [(and (>= code 48) (<= code 57)) (- code 48)]
    [(and (>= code 97) (<= code 102)) (- code 87)]
    [else -1]))

(define (hex-bytes [hex : String]) : byte_buf.ByteBuf
  (let
    [text : (& hex bytes) (byte_buf.str-as-bytes (& hex))]
    [length : i64 (byte_buf.bytes-length text)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (+ (/ length 2) 1))]
    [index : i64 0]
    (begin
      (test.assert-i64-eq (% length 2) 0 "fixture hex has whole bytes")
      (while (< index length)
        (let
          [high : i64 (hex-nibble (cast (byte_buf.bytes-ref text index) : i64))]
          [low : i64
            (hex-nibble (cast (byte_buf.bytes-ref text (+ index 1)) : i64))]
          (begin
            (test.assert-true (and (>= high 0) (>= low 0)) "fixture hex digit")
            (set! out (byte_buf.push out (cast (+ (* high 16) low) : u8)))
            (set! index (+ index 2)))))
      out)))

(define (hex-string [view : (& view bytes)]) : String
  (let
    [digits : String "0123456789abcdef"]
    [out : byte_buf.ByteBuf
      (byte_buf.with-capacity (+ (* 2 (byte_buf.bytes-length view)) 1))]
    [index : i64 0]
    (begin
      (while (< index (byte_buf.bytes-length view))
        (let
          [byte : i64 (cast (byte_buf.bytes-ref view index) : i64)]
          (begin
            (set!
              out
              (byte_buf.push
                out
                (byte_buf.bytes-ref
                  (byte_buf.str-as-bytes (& digits))
                  (/ byte 16))))
            (set!
              out
              (byte_buf.push
                out
                (byte_buf.bytes-ref
                  (byte_buf.str-as-bytes (& digits))
                  (% byte 16))))
            (set! index (+ index 1)))))
      (byte_buf.to-string out))))

(define (view [buf : (& buf byte_buf.ByteBuf)]) : (& buf bytes)
  (byte_buf.as-bytes buf))

(define (assert-hex
  [actual : (& actual bytes)]
  [expected : String]
  [message : String]) : unit
  (test.assert-owned-string-eq (hex-string actual) expected (clone message)))

(define (assert-same
  [actual : (& actual bytes)]
  [expected : (& expected bytes)]
  [message : String]) : unit
  (test.assert-owned-string-eq
    (hex-string actual)
    (hex-string expected)
    (clone message)))

(define (assert-buf
  [actual : byte_buf.ByteBuf]
  [expected : (& expected bytes)]
  [message : String]) : unit
  (assert-same (view (& actual)) expected (clone message)))

(define (assert-buf-hex
  [actual : byte_buf.ByteBuf]
  [expected : String]
  [message : String]) : unit
  (assert-hex (view (& actual)) expected (clone message)))

(define (hex-of [buf : byte_buf.ByteBuf]) : String
  (hex-string (view (& buf))))

(define (len-of [buf : byte_buf.ByteBuf]) : i64
  (byte_buf.len (& buf)))

(define (copy-range [source : (& source bytes)] [start : i64] [count : i64]) : byte_buf.ByteBuf
  (byte_buf.from-bytes-range source start count))

(define (concat [a : (& a bytes)] [b : (& b bytes)]) : byte_buf.ByteBuf
  (byte_buf.append-bytes (byte_buf.from-bytes a) b))

(define (smaller [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (assert-error
  [error : (& error tls.TlsWireError)]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (begin
    (test.assert-i64-eq error.code code (clone (clone message)))
    (test.assert-i64-eq error.offset offset (clone (clone message)))
    (test.assert-i64-eq error.alert alert (clone message))))

(define (expect-check-error
  [result : tls.TlsWireCheck]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (match result
    [(TlsWireOk) (test.assert-true false (clone message))]
    [(TlsWireErr error)
      (assert-error (& error) code offset alert (clone message))]))

(define (expect-check-ok [result : tls.TlsWireCheck] [message : String]) : unit
  (match result
    [(TlsWireOk) unit]
    [(TlsWireErr error)
      (test.assert-owned-string-eq
        (tls.error-name error.code)
        "none"
        (clone message))]))

(define (limits) : tls.TlsWireLimits
  (tls.default-limits))

(define wire-limits : tls.TlsWireLimits
  (tls.default-limits))

(define (limits-with
  [max-plaintext : i64]
  [max-handshake : i64]
  [max-extensions : i64]
  [max-list : i64]
  [max-certificates : i64]
  [max-certificate-bytes : i64]) : tls.TlsWireLimits
  (tls.TlsWireLimits
    max-plaintext
    tls.max-ciphertext-fragment
    max-handshake
    max-extensions
    max-list
    max-certificates
    max-certificate-bytes))

;: The body of the single handshake message `message`.
(define (body-of [message : (& message byte_buf.ByteBuf)]) : (& message bytes)
  (tls.handshake-body (byte_buf.as-bytes message)))

;: The extension types of `extensions`, two bytes each.
(define (extension-types
  [extensions : (& extensions (__tl_dyn-array tls.TlsExtension))]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index (array-length extensions))
        (begin
          (set! out (tls.push-be out (array-ref extensions index).ext-type 2))
          (set! index (+ index 1))))
      out)))

;: Check a response block against the types a ClientHello offered.
(define (check-offered
  [extensions : (& extensions (__tl_dyn-array tls.TlsExtension))]
  [hello-extensions : (& hello-extensions (__tl_dyn-array tls.TlsExtension))]
  [context : i64]) : tls.TlsWireCheck
  (let
    [offered : (__tl_dyn-array i64) (offered-types hello-extensions)]
    (tls.check-solicited extensions (& offered) context)))

;: The extension types of `extensions` as an offered list.
(define (offered-types
  [extensions : (& extensions (__tl_dyn-array tls.TlsExtension))]) : (__tl_dyn-array
    i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (array-length extensions))]
    [index : i64 0]
    (begin
      (while (< index (array-length extensions))
        (begin
          (set! (array-ref out index) (array-ref extensions index).ext-type)
          (set! index (+ index 1))))
      out)))

;: `codes` as two-byte values.
(define (codes-hex [codes : (& codes (__tl_dyn-array i64))]) : String
  (let
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index (array-length codes))
        (begin
          (set! out (tls.push-be out (array-ref codes index) 2))
          (set! index (+ index 1))))
      (hex-string (byte_buf.as-bytes (& out))))))

;: The data of the extension of `ext-type`, which must be present.
(define (extension-of
  [extensions : (& source (__tl_dyn-array tls.TlsExtension))]
  [ext-type : i64]) : (& source bytes)
  (let
    [index : i64 (tls.find-extension extensions ext-type)]
    (begin
      (test.assert-true (>= index 0) "expected extension is present")
      (tls.extension-data extensions index))))

;; --- RFC 8448 vectors -------------------------------------------------------------------
;; RFC 8448 Section 3 ClientHello record (201 bytes).
(define (s3-ch-record) : String
  "16030100c4010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")

;; RFC 8448 Section 3 ServerHello record (95 bytes).
(define (s3-sh-record) : String
  "160303005a020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304")

;; RFC 8448 Section 3 encrypted server flight content: EncryptedExtensions, Certificate, CertificateVerify, Finished (657 bytes).
(define (s3-server-flight) : String
  "080000240022000a00140012001d00170018001901000101010201030104001c00024001000000000b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718")

;; RFC 8448 Section 3 client Finished (36 bytes).
(define (s3-client-finished) : String
  "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61")

;; RFC 8448 Section 3 NewSessionTicket (205 bytes).
(define (s3-nst) : String
  "040000c90000001efad6aac502000000b22c035d829359ee5ff7af4ec900000000262a6494dc486d2c8a34cb33fa90bf1b0070ad3c498883c9367c09a2be785abc55cd226097a3a982117283f82a03a143efd3ff5dd36d64e861be7fd61d2827db279cce145077d454a3664d4e6da4d29ee03725a6a4dafcd0fc67d2aea70529513e3da2677fa5906c5b3f7d8f92f228bda40dda721470f9fbf297b5aea617646fac5c03272e970727c621a79141ef5f7de6505e5bfbc388e93343694093934ae4d3570008002a000400000400")

;; RFC 8448 Section 4 ClientHello with early_data and pre_shared_key (512 bytes).
(define (s4-ch) : String
  "010001fc03031bc3ceb6bbe39cff938355b5a50adb6db21b7a6af649d7b4bc419d7876487d95000006130113031302010001cd0000000b0009000006736572766572ff01000100000a00140012001d00170018001901000101010201030104003300260024001d0020e4ffb68ac05f8d96c99da26698346c6be16482badddafe051a66b4f18d668f0b002a0000002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c0002400100150057000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002900dd00b800b22c035d829359ee5ff7af4ec900000000262a6494dc486d2c8a34cb33fa90bf1b0070ad3c498883c9367c09a2be785abc55cd226097a3a982117283f82a03a143efd3ff5dd36d64e861be7fd61d2827db279cce145077d454a3664d4e6da4d29ee03725a6a4dafcd0fc67d2aea70529513e3da2677fa5906c5b3f7d8f92f228bda40dda721470f9fbf297b5aea617646fac5c03272e970727c621a79141ef5f7de6505e5bfbc388e93343694093934ae4d357fad6aacb0021203add4fb2d8fdf822a0ca3cf7678ef5e88dae990141c5924d57bb6fa31b9e5f9d")

;; RFC 8448 Section 4 ServerHello with pre_shared_key (96 bytes).
(define (s4-sh) : String
  "0200005c03033ccfd2dec890222763472ae8136777c9d7358777bb66e91ea5122495f559ea2d00130100003400290002000000330024001d0020121761ee42c333e1b9e77b60dd57c2053cd94512ab47f115e86eff50942cea31002b00020304")

;; RFC 8448 Section 4 EncryptedExtensions with early_data (44 bytes).
(define (s4-ee) : String
  "080000280026000a00140012001d00170018001901000101010201030104001c0002400100000000002a0000")

;; RFC 8448 Section 4 EndOfEarlyData (4 bytes).
(define (s4-eoed) : String
  "05000000")

;; RFC 8448 Section 5 first ClientHello record (185 bytes).
(define (s5-ch1-record) : String
  "16030100b4010000b00303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a346677b6f000006130113031302010000810000000b0009000006736572766572ff01000100000a00080006001d00170018003300260024001d0020e8e8e3f3b93a25ed97a14a7dcacb8a272c6288e585c6484d05262fcad062ad1f002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")

;; RFC 8448 Section 5 HelloRetryRequest (176 bytes).
(define (s5-hrr) : String
  "020000ac0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c001301000084003300020017002c0074007271dcd04bb88bc3189119398a00000000eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2e23fcc654b1b5b40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b0c8be778257d16aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002b00020304")

;; RFC 8448 Section 5 second ClientHello record, with cookie and a P-256 share (517 bytes).
(define (s5-ch2-record) : String
  "1603030200010001fc0303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a346677b6f000006130113031302010001cd0000000b0009000006736572766572ff01000100000a00080006001d001700180033004700450017004104a6da7392ec591e17abfd535964b99894d13befb221b3def2ebe3830eac8f0151812677c4d6d2237e85cf01d6910cfb83954e76ba7352830534159897e8065780002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002c0074007271dcd04bb88bc3189119398a00000000eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2e23fcc654b1b5b40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b0c8be778257d16aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002d00020101001c00024001001500af00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")

;; RFC 8448 Section 5 ServerHello with a P-256 share (123 bytes).
(define (s5-sh) : String
  "020000770303bb341d847fd789c47c387172dc0c9bf147fccacb5043d86ca4c598d3ff571b9800130100004f003300450017004104583e054b7a66672ae020ad9d2686fcc85b5ad41a134a0f03ee72b893052bd85b4c8de6776f5b04ac07d83540eab3e3d9c547bc6528c4317d294686093a6cad7d002b00020304")

;; RFC 8448 Section 6 CertificateRequest (43 bytes).
(define (s6-cr) : String
  "0d000027000024000d0020001e040305030603020308040805080604010501060102010402050206020202")

;; RFC 8448 Section 6 encrypted server flight content, with CertificateRequest (517 bytes).
(define (s6-server-flight) : String
  "080000240022000a00140012001d00170018001901000101010201030104001c00024001000000000d000027000024000d0020001e0403050306030203080408050806040105010601020104020502060202020b00013b000001370001323082012e3081d5a003020102020107300a06082a8648ce3d04030230133111300f060355040313086563647361323536301e170d3136303733303031323430305a170d3236303733303031323430305a30133111300f0603550403130865636473613235363059301306072a8648ce3d020106082a8648ce3d0301070342000408d530161575f4cfe7f154ee3448180086001e88431a79ee62ee6e2f83ef38ba61e9fb37f34e007a7df4d2f5b56d1f04ece45d621f468406f5c3a15158948dd0a31a301830090603551d1304023000300b0603551d0f040403020780300a06082a8648ce3d0403020348003045022100df30fd4507f5edd22c1a6ff86db479ca693feeca3b71b3f9ef556b2937c0594d022062e2a47250d320fea83c7e2dcb5b76a50e0200c09adbd13fee946e513e011d1100000f00004b040300473045022100d7a4d34bd54f55fee1a89625678c3dd5e5f60dac73ec940c5c7b9304a02084a90220289f595ed488b9ac689a3d192b1a8bb38f34af7874c059c9806a1f38269353e81400002093b70cdf4781985b96345caac701b4e750d3042df1a689d8faca812251113c11")

;; RFC 8448 Section 6 encrypted client flight content: Certificate, CertificateVerify, Finished (623 bytes).
(define (s6-client-flight) : String
  "0b0001bf000001bb0001b6308201b23082011ba003020102020101300d06092a864886f70d01010b05003011310f300d06035504031306636c69656e74301e170d3136303733303031323335395a170d3236303733303031323335395a3011310f300d06035504031306636c69656e7430819f300d06092a864886f70d010101050003818d0030818902818100c38175e004a68d093f823b9c379d201fbc0bb7a1c791905e3fbf76847e44e751ebbcd360bd945c81e5222bcc8846d3a8a0f93e9bf5bebabd92edf1de1ff19021703e7ab6c0901513f97e39b111f09c9348971c7b211984a754cd45fe095af0ea4236829bccf7a7fe9b2888e78ab477690a5b9e1ccbe91c6a4a0f97a7e02842010203010001a31a301830090603551d1304023000300b0603551d0f040403020780300d06092a864886f70d01010b0500038181001a7a5a018532b022af0767d486160cff2d167a1915d23835b54594916dc680be5d2e626076c5d52722ebcc775d7d99f980be2fc94d34acf6cc00ba90cbcfb0608aa1e7e3971ef0c07a41d47ad8345d1f81fe418a1cf41054429fd217bd777dc1cf08f05df90799c659361e0f1a8ee4ac0f7897420bdbc823da80a2f2ba23081c00000f00008408040080186b2223b503a759c35dba0e9721b4b579138d5f0f5e6ec7feaaf27f3ad7f386c2c7bd7cb2be52fbf5ed8393f406ee79369692ec7ac695651d858219e672a8eb7b2a677b640b46ab630edc5f3f2f8272b9c0d906f81f84ddc5b8c7bcf955c78a3cf99e5016f73e04eb7dfcb28833f13e8f75ec2ff3581e2f098ad4157fd6d6ad140000209afe2ba2f63a09d229d8a429e5b37ffd9fcc73bdb5911b82425972aa2892440f")

;; RFC 8448 Section 7 ClientHello with a 32-byte legacy session id (224 bytes).
(define (s7-ch) : String
  "010000dc03034e640a3f2c2738f09c9418bd78edccd7559d0531199276d4d92a0e9ee9d77d0920a80c165581a8e0d06c0018d54d3a06dd32cfd4051eb026fad3fd0ba99269e6ef00061301130313020100008d0000000b0009000006736572766572ff01000100000a00140012001d00170018001901000101010201030104003300260024001d00208e7292cf3056dbb0d25fcbe55c107dc9bbf83dd9708f39203ba341249a7d9b63002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")

;; RFC 8448 Section 7 ServerHello echoing the session id (122 bytes).
(define (s7-sh) : String
  "020000760303e5dd5948c435f7a38f0f0130708dc322d9df09abd4838117c183a7bb6d994f2c20a80c165581a8e0d06c0018d54d3a06dd32cfd4051eb026fad3fd0ba99269e6ef130100002e00330024001d00203e30f0f4ba551afd62768341175f5265e4daf0c8841617aa4fafdd2142320c22002b00020304")

;; RFC 8448 Section 7 compatibility change_cipher_spec record (6 bytes).
(define (s7-ccs-record) : String
  "140303000101")

;; --- records ------------------------------------------------------------------------
;: Feed `input` to a fresh record reader as a first piece of `split` bytes and
;: then pieces of `chunk` bytes, re-encoding every completed record. Each piece
;: is offered again from its first unconsumed byte until it is used up.
(define (reframe
  [input : (& input bytes)]
  [split : i64]
  [chunk : i64]
  [protected : bool]) : byte_buf.ByteBuf
  (let
    [reader : tls.TlsRecordReader (tls.record-reader-new (limits))]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [total : i64 (byte_buf.bytes-length input)]
    [start : i64 0]
    (begin
      (while (< start total)
        (let
          [stop : i64
            (if (= start 0)
              (smaller split total)
              (smaller (+ start chunk) total))]
          [cursor : i64 start]
          (begin
            (while (< cursor stop)
              (match (tls.record-reader-next!
                (&mut reader)
                (byte_buf.bytes-slice-view input cursor (- stop cursor))
                protected)
                [(TlsRecordNeedMore consumed)
                  (begin
                    (test.assert-i64-eq
                      consumed
                      (- stop cursor)
                      "a short piece is consumed whole")
                    (test.assert-true
                      (tls.record-reader-mid-record? (& reader))
                      "a short piece leaves a partial record")
                    (set! cursor stop))]
                [(TlsRecordComplete consumed header)
                  (begin
                    (test.assert-true
                      (> consumed 0)
                      "a record completes on input")
                    (test.assert-false
                      (tls.record-reader-mid-record? (& reader))
                      "a completed record is not partial")
                    (set!
                      out
                      (tls.encode-record
                        out
                        header.content-type
                        header.legacy-version
                        (tls.record-reader-fragment (& reader))))
                    (set! cursor (+ cursor consumed)))]
                [(TlsRecordFailed error)
                  (test.assert-owned-string-eq
                    (tls.error-name error.code)
                    "none"
                    "valid records are accepted")]))
            (set! start stop))))
      out)))

(define (record-stream-plaintext) : byte_buf.ByteBuf
  (let
    [ch : byte_buf.ByteBuf (hex-bytes (s3-ch-record))]
    [sh : byte_buf.ByteBuf (hex-bytes (s3-sh-record))]
    [ccs : byte_buf.ByteBuf (hex-bytes (s7-ccs-record))]
    [alert : byte_buf.ByteBuf (hex-bytes "15030300020232")]
    (byte_buf.append-bytes
      (byte_buf.append-bytes
        (concat (view (& ch)) (view (& sh)))
        (view (& ccs)))
      (view (& alert)))))

(define (record-stream-protected) : byte_buf.ByteBuf
  (let
    [flight : byte_buf.ByteBuf (hex-bytes (s3-server-flight))]
    [out : byte_buf.ByteBuf (hex-bytes (s7-ccs-record))]
    (begin
      (set!
        out
        (tls.encode-record
          out
          tls.content-type-application-data
          tls.legacy-version-tls12
          (view (& flight))))
      (set!
        out
        (tls.encode-record
          out
          tls.content-type-application-data
          tls.legacy-version-tls12
          (byte_buf.bytes-slice-view (view (& flight)) 0 0)))
      (tls.encode-record
        out
        tls.content-type-application-data
        tls.legacy-version-tls12
        (byte_buf.bytes-slice-view (view (& flight)) 7 23)))))

(define (record-splits) : unit
  (let
    [plain : byte_buf.ByteBuf (record-stream-plaintext)]
    [protected : byte_buf.ByteBuf (record-stream-protected)]
    [split : i64 1]
    (begin
      (test.assert-i64-eq (byte_buf.len (& plain)) 309 "plaintext stream size")
      (while (<= split (byte_buf.len (& plain)))
        (begin
          (assert-buf
            (reframe (view (& plain)) split (byte_buf.len (& plain)) false)
            (view (& plain))
            "every two-piece split of plaintext records")
          (set! split (+ split 1))))
      (set! split 1)
      (while (<= split (byte_buf.len (& protected)))
        (begin
          (assert-buf
            (reframe
              (view (& protected))
              split
              (byte_buf.len (& protected))
              true)
            (view (& protected))
            "every two-piece split of protected records")
          (set! split (+ split 1))))
      (assert-buf
        (reframe (view (& plain)) 1 1 false)
        (view (& plain))
        "plaintext records one byte at a time")
      (assert-buf
        (reframe (view (& protected)) 3 7 true)
        (view (& protected))
        "protected records in seven-byte pieces"))))

(define (record-vector-headers) : unit
  (let
    [record : byte_buf.ByteBuf (hex-bytes (s3-ch-record))]
    [reader : tls.TlsRecordReader (tls.record-reader-new (limits))]
    (match (tls.record-reader-next! (&mut reader) (view (& record)) false)
      [(TlsRecordComplete consumed header)
        (begin
          (test.assert-i64-eq consumed 201 "ClientHello record size")
          (test.assert-i64-eq header.content-type 22 "handshake record")
          (test.assert-i64-eq
            header.legacy-version
            0x0301
            "initial record version")
          (test.assert-i64-eq header.length 196 "ClientHello fragment length")
          (test.assert-i64-eq
            (byte_buf.bytes-length (tls.record-reader-fragment (& reader)))
            196
            "fragment view length")
          (test.assert-i64-eq
            (tls.record-reader-offset (& reader))
            0
            "first record offset"))]
      [_ (test.assert-true false "ClientHello record decodes")])))

;: Feed `hex` whole to a fresh reader and expect it to fail, then fail the
;: same way again.
(define (expect-record-error
  [hex : String]
  [protected : bool]
  [record-limits : tls.TlsWireLimits]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (let
    [input : byte_buf.ByteBuf (hex-bytes hex)]
    [reader : tls.TlsRecordReader (tls.record-reader-new record-limits)]
    [failed : bool false]
    [cursor : i64 0]
    (begin
      (while (and (not failed) (< cursor (byte_buf.len (& input))))
        (match (tls.record-reader-next!
          (&mut reader)
          (byte_buf.bytes-slice-view
            (view (& input))
            cursor
            (- (byte_buf.len (& input)) cursor))
          protected)
          [(TlsRecordNeedMore consumed) (set! cursor (+ cursor consumed))]
          [(TlsRecordComplete consumed _) (set! cursor (+ cursor consumed))]
          [(TlsRecordFailed error)
            (begin
              (assert-error (& error) code offset alert (clone message))
              (set! failed true))]))
      (test.assert-true failed (clone message))
      (match (tls.record-reader-next! (&mut reader) (view (& input)) protected)
        [(TlsRecordFailed error)
          (assert-error
            (& error)
            code
            offset
            alert
            "a failed reader stays failed")]
        [_ (test.assert-true false "a failed reader stays failed")]))))

;: Feed `hex` whole and expect exactly one complete record of `length`.
(define (expect-record-ok
  [hex : String]
  [protected : bool]
  [record-limits : tls.TlsWireLimits]
  [length : i64]
  [message : String]) : unit
  (let
    [input : byte_buf.ByteBuf (hex-bytes hex)]
    [reader : tls.TlsRecordReader (tls.record-reader-new record-limits)]
    (match (tls.record-reader-next! (&mut reader) (view (& input)) protected)
      [(TlsRecordComplete consumed header)
        (begin
          (test.assert-i64-eq
            consumed
            (byte_buf.len (& input))
            (clone (clone message)))
          (test.assert-i64-eq header.length length (clone message)))]
      [_ (test.assert-true false (clone message))])))

;: A header for a record of `content-type` and `length` followed by `length`
;: zero bytes (or ones for change_cipher_spec).
(define (record-hex [content-type : i64] [length : i64]) : String
  (let
    [out : byte_buf.ByteBuf
      (tls.encode-record-header (byte_buf.new) content-type 0x0303 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! out (byte_buf.push out 1))
          (set! index (+ index 1))))
      (hex-string (view (& out))))))

(define (record-header-errors) : unit
  (let
    [small : tls.TlsWireLimits (limits-with 1000 262144 64 1024 16 65536)]
    (begin
      (expect-record-error
        "1803030001ff"
        false
        (limits)
        tls.error-content-type
        0
        tls.alert-unexpected-message
        "unknown content type")
      (expect-record-error
        "0003030001ff"
        true
        (limits)
        tls.error-content-type
        0
        tls.alert-unexpected-message
        "content type 0")
      (expect-record-error
        "1703030001ff"
        false
        (limits)
        tls.error-content-type
        0
        tls.alert-unexpected-message
        "application data before protection")
      (expect-record-error
        "1603030001ff"
        true
        (limits)
        tls.error-content-type
        0
        tls.alert-unexpected-message
        "plaintext handshake after protection")
      (expect-record-error
        "15030300020100"
        true
        (limits)
        tls.error-content-type
        0
        tls.alert-unexpected-message
        "plaintext alert after protection")
      (expect-record-error
        "160203000101"
        false
        (limits)
        tls.error-record-version
        1
        tls.alert-decode-error
        "record version major byte")
      (expect-record-error
        "160403000101"
        false
        (limits)
        tls.error-record-version
        1
        tls.alert-decode-error
        "record version major byte 4")
      (expect-record-ok
        "160300000101"
        false
        (limits)
        1
        "SSL 3.0 record version is ignored")
      (expect-record-ok
        "16037f000101"
        false
        (limits)
        1
        "any minor version is ignored")
      (expect-record-error
        "1603034001"
        false
        (limits)
        tls.error-record-overflow
        3
        tls.alert-record-overflow
        "plaintext over 2^14")
      (expect-record-ok
        (record-hex 22 16384)
        false
        (limits)
        16384
        "plaintext of 2^14")
      (expect-record-error
        "1403034001"
        true
        (limits)
        tls.error-record-overflow
        3
        tls.alert-record-overflow
        "compatibility record over 2^14")
      (expect-record-error
        "1703034101"
        true
        (limits)
        tls.error-record-overflow
        3
        tls.alert-record-overflow
        "ciphertext over 2^14 + 256")
      (expect-record-ok
        (record-hex 23 16640)
        true
        (limits)
        16640
        "ciphertext of 2^14 + 256")
      (expect-record-error
        "16030303e9"
        false
        small
        tls.error-record-overflow
        3
        tls.alert-record-overflow
        "plaintext over the caller limit")
      (expect-record-ok
        (record-hex 22 1000)
        false
        small
        1000
        "plaintext at the caller limit")
      (expect-record-error
        "1603030000"
        false
        (limits)
        tls.error-empty-fragment
        3
        tls.alert-unexpected-message
        "empty handshake record")
      (expect-record-error
        "1503030000"
        false
        (limits)
        tls.error-empty-fragment
        3
        tls.alert-unexpected-message
        "empty alert record")
      (expect-record-error
        "1403030000"
        true
        (limits)
        tls.error-empty-fragment
        3
        tls.alert-unexpected-message
        "empty change_cipher_spec record")
      (expect-record-ok
        "1703030000"
        true
        (limits)
        0
        "empty ciphertext record reaches decryption")
      (expect-record-error
        "15030300010a"
        false
        (limits)
        tls.error-alert-length
        3
        tls.alert-decode-error
        "one-byte alert record")
      (expect-record-error
        "15030300030100ff"
        false
        (limits)
        tls.error-alert-length
        3
        tls.alert-decode-error
        "three-byte alert record")
      (expect-record-ok
        "15030300020100"
        false
        (limits)
        2
        "two-byte alert record")
      (expect-record-error
        "14030300020101"
        false
        (limits)
        tls.error-change-cipher-spec
        3
        tls.alert-unexpected-message
        "two-byte change_cipher_spec")
      (expect-record-error
        "14030300010a"
        true
        (limits)
        tls.error-change-cipher-spec
        5
        tls.alert-unexpected-message
        "change_cipher_spec value other than 1")
      (expect-record-error
        "14030300010a"
        false
        (limits)
        tls.error-change-cipher-spec
        5
        tls.alert-unexpected-message
        "plaintext change_cipher_spec value")
      (expect-record-error
        (string-append-hex (s3-ch-record) "1803030001ff")
        false
        (limits)
        tls.error-content-type
        201
        tls.alert-unexpected-message
        "errors carry the stream offset of the failing record")
      (expect-record-error
        (string-append-hex (s3-ch-record) "1603034001")
        false
        (limits)
        tls.error-record-overflow
        204
        tls.alert-record-overflow
        "overflow offsets are stream offsets"))))

(define (string-append-hex [a : String] [b : String]) : String
  (let
    [first : byte_buf.ByteBuf (hex-bytes a)]
    [second : byte_buf.ByteBuf (hex-bytes b)]
    [joined : byte_buf.ByteBuf (concat (view (& first)) (view (& second)))]
    (hex-string (view (& joined)))))

(define (record-partial-input) : unit
  (let
    [record : byte_buf.ByteBuf (hex-bytes (s3-sh-record))]
    [both : byte_buf.ByteBuf (concat (view (& record)) (view (& record)))]
    [reader : tls.TlsRecordReader (tls.record-reader-new (limits))]
    (begin
      (test.assert-false
        (tls.record-reader-mid-record? (& reader))
        "a new reader holds no record")
      (match (tls.record-reader-next!
        (&mut reader)
        (byte_buf.bytes-slice-view (view (& both)) 0 0)
        false)
        [(TlsRecordNeedMore consumed)
          (test.assert-i64-eq consumed 0 "empty input consumes nothing")]
        [_ (test.assert-true false "empty input needs more")])
      (match (tls.record-reader-next! (&mut reader) (view (& both)) false)
        [(TlsRecordComplete consumed _)
          (test.assert-i64-eq consumed 95 "the reader stops at the record end")]
        [_ (test.assert-true false "first of two records")])
      (match (tls.record-reader-next!
        (&mut reader)
        (byte_buf.bytes-slice-view (view (& both)) 95 3)
        false)
        [(TlsRecordNeedMore consumed)
          (begin
            (test.assert-i64-eq consumed 3 "a partial header is buffered")
            (test.assert-i64-eq
              (tls.record-reader-offset (& reader))
              95
              "second record offset")
            (test.assert-true
              (tls.record-reader-mid-record? (& reader))
              "partial header"))]
        [_ (test.assert-true false "partial second header")])
      (match (tls.record-reader-next!
        (&mut reader)
        (byte_buf.bytes-slice-view (view (& both)) 98 92)
        false)
        [(TlsRecordComplete consumed _)
          (begin
            (test.assert-i64-eq consumed 92 "the rest completes the record")
            (assert-same
              (tls.record-reader-fragment (& reader))
              (byte_buf.bytes-slice-view (view (& record)) 5 90)
              "second fragment"))]
        [_ (test.assert-true false "second of two records")]))))

(define (record-reader-allocation) : unit
  (let
    [stream : byte_buf.ByteBuf (record-stream-protected)]
    [reader : tls.TlsRecordReader (tls.record-reader-new (limits))]
    [round : i64 0]
    [before : i64 0]
    (begin
      (while (< round 3)
        (let
          [cursor : i64 0]
          (begin
            (when (= round 1) (set! before (profile.alloc-total)))
            (while (< cursor (byte_buf.len (& stream)))
              (match (tls.record-reader-next!
                (&mut reader)
                (byte_buf.bytes-slice-view
                  (view (& stream))
                  cursor
                  (smaller 50 (- (byte_buf.len (& stream)) cursor)))
                true)
                [(TlsRecordNeedMore consumed) (set! cursor (+ cursor consumed))]
                [(TlsRecordComplete consumed _)
                  (set! cursor (+ cursor consumed))]
                [(TlsRecordFailed _) (test.assert-true false "stream decodes")]))
            (set! round (+ round 1)))))
      (test.assert-i64-eq
        (- (profile.alloc-total) before)
        0
        "a warmed record reader allocates nothing"))))

(define (inner-plaintext) : unit
  (let
    [alert : byte_buf.ByteBuf (hex-bytes "0100")]
    [padded : byte_buf.ByteBuf
      (tls.encode-inner-plaintext (byte_buf.new) (view (& alert)) 21 10)]
    [big : tls.TlsWireLimits (limits)]
    [small : tls.TlsWireLimits (limits-with 100 262144 64 1024 16 65536)]
    (begin
      (assert-hex
        (view (& padded))
        "01001500000000000000000000"
        "inner plaintext layout")
      (match (tls.decode-inner-plaintext (view (& padded)) (& big))
        [(TlsInnerPlaintextOk inner)
          (begin
            (test.assert-i64-eq inner.content-type 21 "inner alert type")
            (test.assert-i64-eq inner.length 2 "inner alert length"))]
        [_ (test.assert-true false "padded alert decodes")])
      (expect-inner-error
        "00000000"
        (& big)
        tls.error-missing-content-type
        0
        tls.alert-unexpected-message
        "all padding")
      (expect-inner-error
        ""
        (& big)
        tls.error-missing-content-type
        0
        tls.alert-unexpected-message
        "empty plaintext")
      (expect-inner-error
        "011400"
        (& big)
        tls.error-content-type
        1
        tls.alert-unexpected-message
        "protected change_cipher_spec")
      (expect-inner-error
        "01ff"
        (& big)
        tls.error-content-type
        1
        tls.alert-unexpected-message
        "unknown inner type")
      (expect-inner-error
        "160000"
        (& big)
        tls.error-empty-fragment
        0
        tls.alert-unexpected-message
        "empty handshake content")
      (expect-inner-error
        "15"
        (& big)
        tls.error-empty-fragment
        0
        tls.alert-unexpected-message
        "empty alert content")
      (expect-inner-error
        "01000015"
        (& big)
        tls.error-alert-length
        3
        tls.alert-decode-error
        "three-byte alert content")
      (expect-inner-ok "1700" (& big) 23 0 "empty application data")
      (expect-inner-ok
        (filled-hex 100 23)
        (& small)
        23
        100
        "content at the caller limit")
      (expect-inner-error
        (filled-hex 101 23)
        (& small)
        tls.error-record-overflow
        101
        tls.alert-record-overflow
        "content over the caller limit")
      (expect-inner-ok (filled-hex 16384 22) (& big) 22 16384 "content of 2^14")
      (expect-inner-error
        (filled-hex 16385 22)
        (& big)
        tls.error-record-overflow
        0
        tls.alert-record-overflow
        "plaintext over 2^14 + 1")
      (expect-inner-error
        (string-append-hex (filled-hex 16384 22) "00")
        (& big)
        tls.error-record-overflow
        0
        tls.alert-record-overflow
        "padding counts toward 2^14 + 1"))))

;: `count` bytes of 0xaa followed by the type byte.
(define (filled-hex [count : i64] [content-type : i64]) : String
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (+ count 1))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! out (byte_buf.push out 0xaa))
          (set! index (+ index 1))))
      (hex-of (tls.push-be out content-type 1)))))

(define (expect-inner-error
  [hex : String]
  [inner-limits : (& inner-limits tls.TlsWireLimits)]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (let
    [plaintext : byte_buf.ByteBuf (hex-bytes hex)]
    (match (tls.decode-inner-plaintext (view (& plaintext)) inner-limits)
      [(TlsInnerPlaintextErr error)
        (assert-error (& error) code offset alert (clone message))]
      [(TlsInnerPlaintextOk _) (test.assert-true false (clone message))])))

(define (expect-inner-ok
  [hex : String]
  [inner-limits : (& inner-limits tls.TlsWireLimits)]
  [content-type : i64]
  [length : i64]
  [message : String]) : unit
  (let
    [plaintext : byte_buf.ByteBuf (hex-bytes hex)]
    (match (tls.decode-inner-plaintext (view (& plaintext)) inner-limits)
      [(TlsInnerPlaintextOk inner)
        (begin
          (test.assert-i64-eq inner.content-type content-type (clone message))
          (test.assert-i64-eq inner.length length (clone message)))]
      [(TlsInnerPlaintextErr error)
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          (clone message))])))

;; --- handshake reassembly ---------------------------------------------------------
;: Messages reassembled from a fragmented feed: their concatenated encodings,
;: one type byte each, and one byte each that is 1 when the reader reported a
;: record boundary after the message.
(defstruct Reassembly
  (frames byte_buf.ByteBuf)
  (types byte_buf.ByteBuf)
  (boundaries byte_buf.ByteBuf))

;: Feed `content` to a fresh handshake reader as a first fragment of `split`
;: bytes and then fragments of `chunk` bytes, draining after each.
(define (reassemble [content : (& content bytes)] [split : i64] [chunk : i64]) : Reassembly
  (let
    [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
    [result : Reassembly
      (Reassembly (byte_buf.new) (byte_buf.new) (byte_buf.new))]
    [total : i64 (byte_buf.bytes-length content)]
    [start : i64 0]
    (begin
      (while (< start total)
        (let
          [stop : i64
            (if (= start 0)
              (smaller split total)
              (smaller (+ start chunk) total))]
          [draining : bool true]
          (begin
            (expect-check-ok
              (tls.handshake-reader-feed!
                (&mut reader)
                (byte_buf.bytes-slice-view content start (- stop start)))
              "fragments feed")
            (while draining
              (match (tls.handshake-reader-next! (&mut reader))
                [(TlsHandshakeReady msg-type body-length)
                  (let
                    [message : (& reader bytes)
                      (tls.handshake-reader-message (& reader))]
                    [offset : i64
                      (tls.handshake-reader-message-offset (& reader))]
                    [ends-fragment : bool
                      (= (+ offset (byte_buf.bytes-length message)) stop)]
                    (begin
                      (test.assert-i64-eq
                        offset
                        (byte_buf.len (& result.frames))
                        "message offsets follow the stream")
                      (test.assert-i64-eq
                        (byte_buf.bytes-length message)
                        (+ body-length 4)
                        "message view covers header and body")
                      (test.assert-i64-eq
                        (tls.read-be message 0 1)
                        msg-type
                        "message type")
                      (test.assert-bool-eq
                        (tls.handshake-reader-at-record-boundary? (& reader))
                        ends-fragment
                        "record boundary after a message")
                      (set!
                        result.frames
                        (byte_buf.append-bytes result.frames message))
                      (set!
                        result.types
                        (byte_buf.push result.types (cast msg-type : u8)))
                      (set!
                        result.boundaries
                        (byte_buf.push
                          result.boundaries
                          (if ends-fragment
                            1
                            0)))))]
                [(TlsHandshakeNeedMore)
                  (begin
                    (test.assert-bool-eq
                      (tls.handshake-reader-buffering? (& reader))
                      (!= (byte_buf.len (& result.frames)) stop)
                      "a partial message is buffered exactly when the fragment ends inside one")
                    (set! draining false))]
                [(TlsHandshakeFailed error)
                  (begin
                    (test.assert-owned-string-eq
                      (tls.error-name error.code)
                      "none"
                      "valid messages reassemble")
                    (set! draining false))]))
            (set! start stop))))
      result)))

(define (assert-flight
  [content : (& content bytes)]
  [types : String]
  [split : i64]
  [chunk : i64]
  [message : String]) : unit
  (let
    [result : Reassembly (reassemble content split chunk)]
    (begin
      (assert-same (view (& result.frames)) content (clone message))
      (assert-hex (view (& result.types)) types (clone message)))))

(define (handshake-splits) : unit
  (let
    [s3 : byte_buf.ByteBuf (hex-bytes (s3-server-flight))]
    [s6 : byte_buf.ByteBuf (hex-bytes (s6-server-flight))]
    [client : byte_buf.ByteBuf (hex-bytes (s6-client-flight))]
    [split : i64 1]
    (begin
      (while (<= split (byte_buf.len (& s3)))
        (begin
          (assert-flight
            (view (& s3))
            "080b0f14"
            split
            (byte_buf.len (& s3))
            "every two-fragment split of the server flight")
          (set! split (+ split 1))))
      (set! split 1)
      (while (<= split (byte_buf.len (& s6)))
        (begin
          (assert-flight
            (view (& s6))
            "080d0b0f14"
            split
            (byte_buf.len (& s6))
            "every two-fragment split of the client-auth server flight")
          (set! split (+ split 1))))
      (assert-flight (view (& s3)) "080b0f14" 1 1 "one-byte fragments")
      (assert-flight (view (& s6)) "080d0b0f14" 3 2 "two-byte fragments")
      (assert-flight (view (& client)) "0b0f14" 5 7 "seven-byte fragments")
      (assert-flight (view (& client)) "0b0f14" 623 623 "one fragment")
      (let
        [whole : Reassembly (reassemble (view (& s3)) 657 657)]
        (assert-hex
          (view (& whole.boundaries))
          "00000001"
          "only the last message of a coalesced flight ends the record"))
      (let
        [pieces : Reassembly (reassemble (view (& s3)) 40 441)]
        (assert-hex
          (view (& pieces.boundaries))
          "01000001"
          "a message ending its record is on a boundary")))))

(define (handshake-framing-rules) : unit
  (let
    [sh-record : byte_buf.ByteBuf (hex-bytes (s3-sh-record))]
    [sh : (& sh-record bytes)
      (byte_buf.bytes-slice-view (view (& sh-record)) 5 90)]
    [flight : byte_buf.ByteBuf (hex-bytes (s3-server-flight))]
    [sh-and-more : byte_buf.ByteBuf
      (concat sh (byte_buf.bytes-slice-view (view (& flight)) 0 10))]
    (begin
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        (begin
          (test.assert-true
            (tls.handshake-reader-at-record-boundary? (& reader))
            "a new reader is on a boundary")
          (expect-check-ok
            (tls.handshake-reader-feed! (&mut reader) sh)
            "ServerHello feeds")
          (test.assert-false
            (tls.handshake-reader-at-record-boundary? (& reader))
            "an unread message is not on a boundary")
          (match (tls.handshake-reader-next! (&mut reader))
            [(TlsHandshakeReady msg-type body-length)
              (begin
                (test.assert-i64-eq msg-type 2 "ServerHello type")
                (test.assert-i64-eq body-length 86 "ServerHello body"))]
            [_ (test.assert-true false "ServerHello reassembles")])
          (expect-check-ok
            (tls.handshake-reader-check-key-change (&mut reader))
            "a ServerHello ending its record allows the key change")
          (expect-check-ok
            (tls.handshake-reader-note-record!
              (&mut reader)
              tls.content-type-alert)
            "other records are fine between messages")))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed! (&mut reader) (view (& sh-and-more)))
            "ServerHello with trailing bytes feeds")
          (match (tls.handshake-reader-next! (&mut reader))
            [(TlsHandshakeReady msg-type _)
              (test.assert-i64-eq msg-type 2 "ServerHello first")]
            [_ (test.assert-true false "ServerHello reassembles")])
          (expect-check-error
            (tls.handshake-reader-check-key-change (&mut reader))
            tls.error-key-change-unaligned
            90
            tls.alert-unexpected-message
            "bytes after a key-change message in its record")
          (expect-check-error
            (tls.handshake-reader-feed! (&mut reader) sh)
            tls.error-key-change-unaligned
            90
            tls.alert-unexpected-message
            "the failure is sticky")))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed!
              (&mut reader)
              (byte_buf.bytes-slice-view (view (& flight)) 0 10))
            "partial message feeds")
          (expect-check-ok
            (tls.handshake-reader-note-record!
              (&mut reader)
              tls.content-type-handshake)
            "handshake records continue a split message")
          (expect-check-error
            (tls.handshake-reader-note-record!
              (&mut reader)
              tls.content-type-change-cipher-spec)
            tls.error-interleaved
            10
            tls.alert-unexpected-message
            "another record inside a split message")
          (match (tls.handshake-reader-next! (&mut reader))
            [(TlsHandshakeFailed error)
              (assert-error
                (& error)
                tls.error-interleaved
                10
                tls.alert-unexpected-message
                "next after the failure")]
            [_ (test.assert-true false "next after the failure")])))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        (expect-check-error
          (tls.handshake-reader-feed!
            (&mut reader)
            (byte_buf.bytes-slice-view (view (& flight)) 0 0))
          tls.error-empty-fragment
          0
          tls.alert-unexpected-message
          "an empty handshake fragment"))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        [one : byte_buf.ByteBuf (hex-bytes "18000001")]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed! (&mut reader) (view (& one)))
            "a header alone feeds")
          (match (tls.handshake-reader-next! (&mut reader))
            [(TlsHandshakeNeedMore) unit]
            [_ (test.assert-true false "a header alone needs its body")])
          (test.assert-true
            (tls.handshake-reader-buffering? (& reader))
            "a header alone is buffered")))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed!
              (&mut reader)
              (byte_buf.bytes-slice-view (view (& flight)) 0 40))
            "a whole message feeds")
          (test.assert-false
            (tls.handshake-reader-buffering? (& reader))
            "a whole unread message is not a split one")
          (test.assert-false
            (tls.handshake-reader-at-record-boundary? (& reader))
            "a whole unread message is not yet returned")
          (expect-check-ok
            (tls.handshake-reader-note-record!
              (&mut reader)
              tls.content-type-alert)
            "another record may follow whole messages")
          (expect-check-ok
            (tls.handshake-reader-feed!
              (&mut reader)
              (byte_buf.bytes-slice-view (view (& flight)) 40 3))
            "a partial header feeds")
          (test.assert-true
            (tls.handshake-reader-buffering? (& reader))
            "a partial header after a whole message is buffered")
          (expect-check-error
            (tls.handshake-reader-note-record!
              (&mut reader)
              tls.content-type-alert)
            tls.error-interleaved
            43
            tls.alert-unexpected-message
            "another record after a partial header"))))))

(define (expect-feed-error
  [hex : String]
  [feed-limits : tls.TlsWireLimits]
  [offset : i64]
  [message : String]) : unit
  (let
    [reader : tls.TlsHandshakeReader (tls.handshake-reader-new feed-limits)]
    [input : byte_buf.ByteBuf (hex-bytes hex)]
    (expect-check-error
      (tls.handshake-reader-feed! (&mut reader) (view (& input)))
      tls.error-message-too-large
      offset
      tls.alert-decode-error
      (clone message))))

(define (handshake-size-limits) : unit
  (let
    [small : tls.TlsWireLimits (limits-with 16384 100 64 1024 16 65536)]
    (begin
      (expect-feed-error
        "01000065"
        small
        1
        "a body over the limit fails at its header")
      (expect-feed-error
        "0800000200000b000065"
        small
        7
        "every buffered header is checked")
      (expect-feed-error "ff000065" small 1 "unknown types are bounded too")
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new small)]
        [header : byte_buf.ByteBuf (hex-bytes "0b0000")]
        [length : byte_buf.ByteBuf (hex-bytes "65")]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed! (&mut reader) (view (& header)))
            "a partial header feeds")
          (expect-check-error
            (tls.handshake-reader-feed! (&mut reader) (view (& length)))
            tls.error-message-too-large
            1
            tls.alert-decode-error
            "a split header is checked once complete")))
      (let
        [reader : tls.TlsHandshakeReader (tls.handshake-reader-new small)]
        [input : byte_buf.ByteBuf
          (hex-bytes (string-append-hex "0b000064" (filled-hex 99 1)))]
        (begin
          (expect-check-ok
            (tls.handshake-reader-feed! (&mut reader) (view (& input)))
            "a body at the limit")
          (match (tls.handshake-reader-next! (&mut reader))
            [(TlsHandshakeReady msg-type body-length)
              (begin
                (test.assert-i64-eq msg-type 11 "limit message type")
                (test.assert-i64-eq body-length 100 "limit message body"))]
            [_ (test.assert-true false "a body at the limit reassembles")]))))))

(define (handshake-reader-allocation) : unit
  (let
    [flight : byte_buf.ByteBuf (hex-bytes (s3-server-flight))]
    [reader : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
    [round : i64 0]
    [before : i64 0]
    (begin
      (while (< round 3)
        (let
          [cursor : i64 0]
          (begin
            (when (= round 1) (set! before (profile.alloc-total)))
            (while (< cursor (byte_buf.len (& flight)))
              (let
                [count : i64 (smaller 100 (- (byte_buf.len (& flight)) cursor))]
                [draining : bool true]
                (begin
                  (expect-check-ok
                    (tls.handshake-reader-feed!
                      (&mut reader)
                      (byte_buf.bytes-slice-view (view (& flight)) cursor count))
                    "flight feeds")
                  (while draining
                    (match (tls.handshake-reader-next! (&mut reader))
                      [(TlsHandshakeReady _ _) unit]
                      [_ (set! draining false)]))
                  (set! cursor (+ cursor count)))))
            (set! round (+ round 1)))))
      (test.assert-i64-eq
        (- (profile.alloc-total) before)
        0
        "a warmed handshake reader allocates nothing"))))

(define (fragmenting-encoder) : unit
  (let
    [flight : byte_buf.ByteBuf (hex-bytes (s3-server-flight))]
    [records : byte_buf.ByteBuf
      (tls.encode-handshake-records (byte_buf.new) 0x0303 (view (& flight)) 100)]
    [reader : tls.TlsRecordReader (tls.record-reader-new (limits))]
    [messages : tls.TlsHandshakeReader (tls.handshake-reader-new (limits))]
    [frames : byte_buf.ByteBuf (byte_buf.new)]
    [count : i64 0]
    [cursor : i64 0]
    (begin
      (test.assert-i64-eq
        (byte_buf.len (& records))
        (+ 657 (* 7 5))
        "seven records of at most 100 bytes")
      (while (< cursor (byte_buf.len (& records)))
        (match (tls.record-reader-next!
          (&mut reader)
          (byte_buf.bytes-slice-view
            (view (& records))
            cursor
            (- (byte_buf.len (& records)) cursor))
          false)
          [(TlsRecordComplete consumed header)
            (begin
              (set! cursor (+ cursor consumed))
              (set! count (+ count 1))
              (test.assert-i64-eq header.content-type 22 "handshake records")
              (test.assert-true (<= header.length 100) "fragment bound")
              (expect-check-ok
                (tls.handshake-reader-feed!
                  (&mut messages)
                  (tls.record-reader-fragment (& reader)))
                "fragments feed")
              (let
                [draining : bool true]
                (while draining
                  (match (tls.handshake-reader-next! (&mut messages))
                    [(TlsHandshakeReady _ _)
                      (set!
                        frames
                        (byte_buf.append-bytes
                          frames
                          (tls.handshake-reader-message (& messages))))]
                    [_ (set! draining false)]))))]
          [_
            (begin
              (test.assert-true false "encoded records decode")
              (set! cursor (byte_buf.len (& records))))]))
      (test.assert-i64-eq count 7 "record count")
      (assert-same
        (view (& frames))
        (view (& flight))
        "messages survive fragmentation")
      (test.assert-i64-eq
        (len-of
          (tls.encode-handshake-records
            (byte_buf.new)
            0x0303
            (byte_buf.bytes-slice-view (view (& flight)) 0 0)
            100))
        0
        "no records for no messages")
      (let
        [digest : byte_buf.ByteBuf (hex-bytes (filled-hex 31 0xbb))]
        (assert-buf-hex
          (tls.message-hash-frame (view (& digest)))
          (string-append-hex "fe000020" (hex-string (view (& digest))))
          "message_hash frame")))))

;; --- message vectors ------------------------------------------------------------------
;: The handshake message in a single-record vector.
(define (record-message [hex : String]) : byte_buf.ByteBuf
  (let
    [record : byte_buf.ByteBuf (hex-bytes hex)]
    (copy-range (view (& record)) 5 (- (byte_buf.len (& record)) 5))))

;: Message `index` of a coalesced flight.
(define (flight-message [hex : String] [index : i64]) : byte_buf.ByteBuf
  (let
    [flight : byte_buf.ByteBuf (hex-bytes hex)]
    [cursor : i64 0]
    [seen : i64 0]
    (begin
      (while (< seen index)
        (begin
          (set!
            cursor
            (+ (+ cursor 4) (tls.read-be (view (& flight)) (+ cursor 1) 3)))
          (set! seen (+ seen 1))))
      (copy-range
        (view (& flight))
        cursor
        (+ 4 (tls.read-be (view (& flight)) (+ cursor 1) 3))))))

(define (client-hello [message : (& message byte_buf.ByteBuf)]) : tls.TlsClientHello
  (match (tls.decode-client-hello (body-of message) (& wire-limits))
    [(TlsClientHelloOk hello) hello]
    [(TlsClientHelloErr error)
      (begin
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          "ClientHello vector decodes")
        (tls.TlsClientHello
          0
          (byte_buf.new)
          (byte_buf.new)
          (__tl_make-array i64 0)
          (byte_buf.new)
          (__tl_make-array tls.TlsExtension 0)))]))

(define (server-hello [message : (& message byte_buf.ByteBuf)]) : tls.TlsServerHello
  (match (tls.decode-server-hello (body-of message) (& wire-limits))
    [(TlsServerHelloOk hello) hello]
    [(TlsServerHelloErr error)
      (begin
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          "ServerHello vector decodes")
        (tls.TlsServerHello
          0
          (byte_buf.new)
          (byte_buf.new)
          0
          (__tl_make-array tls.TlsExtension 0)))]))

(define (codes [result : tls.TlsCodesResult]) : String
  (match result
    [(TlsCodesOk values) (codes-hex (& values))]
    [(TlsCodesErr error) (tls.error-name error.code)]))

(define (code [result : tls.TlsCodeResult]) : i64
  (match result
    [(TlsCodeOk value) value]
    [(TlsCodeErr error) (- 0 error.code)]))

(define (bytes-hex [result : tls.TlsBytesResult]) : String
  (match result
    [(TlsBytesOk value) (hex-string (view (& value)))]
    [(TlsBytesErr error) (tls.error-name error.code)]))

(define (client-hello-vectors) : unit
  (let
    [s3 : byte_buf.ByteBuf (record-message (s3-ch-record))]
    [hello : tls.TlsClientHello (client-hello (& s3))]
    (begin
      (test.assert-i64-eq hello.legacy-version 0x0303 "legacy_version")
      (assert-hex
        (view (& hello.random))
        "cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7"
        "random")
      (test.assert-i64-eq
        (byte_buf.len (& hello.legacy-session-id))
        0
        "empty session id")
      (test.assert-owned-string-eq
        (codes-hex (& hello.cipher-suites))
        "130113031302"
        "cipher suites")
      (assert-hex
        (view (& hello.legacy-compression-methods))
        "00"
        "compression methods")
      (assert-buf-hex
        (extension-types (& hello.extensions))
        "0000ff01000a00230033002b000d002d001c"
        "extension order, unrecognized ones kept")
      (test.assert-false
        (tls.extension-recognized? 0xff01)
        "renegotiation_info is not TLS 1.3")
      (test.assert-false
        (tls.extension-recognized? 0x23)
        "session_ticket is not TLS 1.3")
      (test.assert-owned-string-eq
        (bytes-hex
          (tls.decode-server-name
            (extension-of (& hello.extensions) tls.extension-server-name)))
        "736572766572"
        "server_name host")
      (test.assert-owned-string-eq
        (codes
          (tls.decode-supported-groups
            (extension-of (& hello.extensions) tls.extension-supported-groups)
            (& wire-limits)))
        "001d00170018001901000101010201030104"
        "supported_groups")
      (test.assert-owned-string-eq
        (codes
          (tls.decode-supported-versions
            (extension-of (& hello.extensions) tls.extension-supported-versions)
            (& wire-limits)))
        "0304"
        "supported_versions")
      (test.assert-owned-string-eq
        (codes
          (tls.decode-signature-schemes
            (extension-of
              (& hello.extensions)
              tls.extension-signature-algorithms)
            (& wire-limits)))
        "040305030603020308040805080604010501060102010402050206020202"
        "signature_algorithms")
      (test.assert-owned-string-eq
        (codes
          (tls.decode-psk-key-exchange-modes
            (extension-of
              (& hello.extensions)
              tls.extension-psk-key-exchange-modes)
            (& wire-limits)))
        "0001"
        "psk_key_exchange_modes")
      (assert-hex
        (extension-of (& hello.extensions) tls.extension-record-size-limit)
        "4001"
        "record_size_limit kept raw")
      (match (tls.decode-key-share-client-hello
        (extension-of (& hello.extensions) tls.extension-key-share)
        (& wire-limits))
        [(TlsKeySharesOk shares)
          (begin
            (test.assert-i64-eq (array-length shares) 1 "one key share")
            (test.assert-i64-eq (array-ref shares 0).group 0x1d "x25519 share")
            (assert-hex
              (view (& (array-ref shares 0).key-exchange))
              "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c"
              "key_exchange"))]
        [_ (test.assert-true false "key_share decodes")])
      (assert-buf
        (tls.encode-client-hello (byte_buf.new) (& hello))
        (view (& s3))
        "ClientHello re-encodes")
      (roundtrip-client-hello (s4-ch) "section 4 ClientHello")
      (roundtrip-client-hello
        (hex-of (record-message (s5-ch1-record)))
        "section 5 first ClientHello")
      (roundtrip-client-hello
        (hex-of (record-message (s5-ch2-record)))
        "section 5 second ClientHello")
      (roundtrip-client-hello (s7-ch) "section 7 ClientHello")
      (let
        [s4 : byte_buf.ByteBuf (hex-bytes (s4-ch))]
        [psk : tls.TlsClientHello (client-hello (& s4))]
        (begin
          (test.assert-i64-eq
            (array-ref psk.extensions (- (array-length psk.extensions) 1)).ext-type
            tls.extension-pre-shared-key
            "pre_shared_key is last")
          (expect-check-ok
            (tls.decode-empty-extension
              (extension-of (& psk.extensions) tls.extension-early-data))
            "ClientHello early_data is empty")))
      (let
        [ch2 : byte_buf.ByteBuf (record-message (s5-ch2-record))]
        [retry : tls.TlsClientHello (client-hello (& ch2))]
        (begin
          (test.assert-i64-eq
            (byte_buf.bytes-length
              (extension-of (& retry.extensions) tls.extension-cookie))
            116
            "cookie extension")
          (match (tls.decode-key-share-client-hello
            (extension-of (& retry.extensions) tls.extension-key-share)
            (& wire-limits))
            [(TlsKeySharesOk shares)
              (begin
                (test.assert-i64-eq
                  (array-ref shares 0).group
                  0x17
                  "P-256 share")
                (test.assert-i64-eq
                  (byte_buf.len (& (array-ref shares 0).key-exchange))
                  65
                  "uncompressed point"))]
            [_ (test.assert-true false "P-256 key_share decodes")])))
      (let
        [s7 : byte_buf.ByteBuf (hex-bytes (s7-ch))]
        [compat : tls.TlsClientHello (client-hello (& s7))]
        (test.assert-i64-eq
          (byte_buf.len (& compat.legacy-session-id))
          32
          "compatibility session id")))))

(define (roundtrip-client-hello [hex : String] [message : String]) : unit
  (let
    [encoded : byte_buf.ByteBuf (hex-bytes hex)]
    [hello : tls.TlsClientHello (client-hello (& encoded))]
    (assert-buf
      (tls.encode-client-hello (byte_buf.new) (& hello))
      (view (& encoded))
      (clone message))))

(define (roundtrip-server-hello
  [hex : String]
  [retry : bool]
  [message : String]) : unit
  (let
    [encoded : byte_buf.ByteBuf (hex-bytes hex)]
    [hello : tls.TlsServerHello (server-hello (& encoded))]
    (begin
      (test.assert-bool-eq
        (tls.server-hello-retry? (& hello))
        retry
        (clone message))
      (test.assert-i64-eq hello.cipher-suite 0x1301 (clone message))
      (test.assert-i64-eq
        (code
          (tls.decode-selected-version
            (extension-of (& hello.extensions) tls.extension-supported-versions)))
        0x0304
        (clone message))
      (assert-buf
        (tls.encode-server-hello (byte_buf.new) (& hello))
        (view (& encoded))
        (clone message)))))

(define (server-hello-vectors) : unit
  (let
    [s3 : byte_buf.ByteBuf (record-message (s3-sh-record))]
    [hello : tls.TlsServerHello (server-hello (& s3))]
    [ch : byte_buf.ByteBuf (record-message (s3-ch-record))]
    [offered : tls.TlsClientHello (client-hello (& ch))]
    [ch1 : byte_buf.ByteBuf (record-message (s5-ch1-record))]
    [first : tls.TlsClientHello (client-hello (& ch1))]
    [hrr-bytes : byte_buf.ByteBuf (hex-bytes (s5-hrr))]
    [hrr : tls.TlsServerHello (server-hello (& hrr-bytes))]
    [psk-bytes : byte_buf.ByteBuf (hex-bytes (s4-sh))]
    [psk : tls.TlsServerHello (server-hello (& psk-bytes))]
    (begin
      (roundtrip-server-hello
        (hex-string (view (& s3)))
        false
        "section 3 ServerHello")
      (roundtrip-server-hello (s4-sh) false "section 4 ServerHello")
      (roundtrip-server-hello (s5-hrr) true "section 5 HelloRetryRequest")
      (roundtrip-server-hello (s5-sh) false "section 5 ServerHello")
      (roundtrip-server-hello (s7-sh) false "section 7 ServerHello")
      (test.assert-i64-eq
        (byte_buf.len (& hello.legacy-session-id-echo))
        0
        "empty session echo")
      (match (tls.decode-key-share-server-hello
        (extension-of (& hello.extensions) tls.extension-key-share))
        [(TlsKeyShareOk share)
          (begin
            (test.assert-i64-eq share.group 0x1d "server x25519 share")
            (assert-hex
              (view (& share.key-exchange))
              "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f"
              "server key_exchange"))]
        [_ (test.assert-true false "server key_share decodes")])
      (assert-buf
        (tls.hello-retry-request-random)
        (view (& hrr.random))
        "HelloRetryRequest random")
      (test.assert-false
        (tls.hello-retry-request-random? (view (& hello.random)))
        "an ordinary random is not the HelloRetryRequest one")
      (test.assert-i64-eq
        (code
          (tls.decode-key-share-hello-retry
            (extension-of (& hrr.extensions) tls.extension-key-share)))
        0x17
        "HelloRetryRequest selects P-256")
      (let
        [ch2 : byte_buf.ByteBuf (record-message (s5-ch2-record))]
        [second : tls.TlsClientHello (client-hello (& ch2))]
        (assert-same
          (extension-of (& hrr.extensions) tls.extension-cookie)
          (extension-of (& second.extensions) tls.extension-cookie)
          "the second ClientHello echoes the cookie"))
      (test.assert-i64-eq
        (string-length
          (bytes-hex
            (tls.decode-cookie
              (extension-of (& hrr.extensions) tls.extension-cookie))))
        228
        "cookie body")
      (assert-hex
        (extension-of (& psk.extensions) tls.extension-pre-shared-key)
        "0000"
        "selected identity")
      (expect-check-ok
        (check-offered
          (& hello.extensions)
          (& offered.extensions)
          tls.context-server-hello)
        "ServerHello answers only offered extensions")
      (expect-check-ok
        (check-offered
          (& hrr.extensions)
          (& first.extensions)
          tls.context-hello-retry-request)
        "a HelloRetryRequest cookie needs no offer")
      (expect-check-error
        (check-offered
          (& hrr.extensions)
          (& first.extensions)
          tls.context-server-hello)
        tls.error-unsolicited-extension
        1
        tls.alert-unsupported-extension
        "a cookie in a ServerHello needs an offer")
      (expect-check-error
        (check-offered
          (& psk.extensions)
          (& offered.extensions)
          tls.context-server-hello)
        tls.error-unsolicited-extension
        0
        tls.alert-unsupported-extension
        "pre_shared_key the client did not offer"))))

(define (encrypted-extensions [message : (& message byte_buf.ByteBuf)]) : (__tl_dyn-array
    tls.TlsExtension)
  (match (tls.decode-encrypted-extensions (body-of message) (& wire-limits))
    [(TlsExtensionsOk extensions) extensions]
    [(TlsExtensionsErr error)
      (begin
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          "EncryptedExtensions vector decodes")
        (__tl_make-array tls.TlsExtension 0))]))

(define (certificate [message : (& message byte_buf.ByteBuf)]) : tls.TlsCertificate
  (match (tls.decode-certificate (body-of message) (& wire-limits))
    [(TlsCertificateOk value) value]
    [(TlsCertificateErr error)
      (begin
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          "Certificate vector decodes")
        (tls.TlsCertificate
          (byte_buf.new)
          (__tl_make-array tls.TlsCertificateEntry 0)))]))

(define (certificate-verify [message : (& message byte_buf.ByteBuf)]) : tls.TlsCertificateVerify
  (match (tls.decode-certificate-verify (body-of message))
    [(TlsCertificateVerifyOk value) value]
    [(TlsCertificateVerifyErr error)
      (begin
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          "CertificateVerify vector decodes")
        (tls.TlsCertificateVerify 0 (byte_buf.new)))]))

(define (check-certificate-message
  [hex : String]
  [index : i64]
  [data-length : i64]
  [message : String]) : unit
  (let
    [encoded : byte_buf.ByteBuf (flight-message hex index)]
    [value : tls.TlsCertificate (certificate (& encoded))]
    (begin
      (test.assert-i64-eq (byte_buf.len (& value.context)) 0 (clone message))
      (test.assert-i64-eq (array-length value.entries) 1 (clone message))
      (test.assert-i64-eq
        (byte_buf.len (& (array-ref value.entries 0).data))
        data-length
        (clone message))
      (test.assert-i64-eq
        (array-length (array-ref value.entries 0).extensions)
        0
        (clone message))
      (test.assert-i64-eq
        (cast (byte_buf.ref (& (array-ref value.entries 0).data) 0) : i64)
        0x30
        (clone message))
      (assert-buf
        (tls.encode-certificate (byte_buf.new) (& value))
        (view (& encoded))
        (clone message)))))

(define (check-verify-and-finished
  [hex : String]
  [first : i64]
  [algorithm : i64]
  [signature-length : i64]
  [message : String]) : unit
  (let
    [verify-bytes : byte_buf.ByteBuf (flight-message (clone hex) first)]
    [verify : tls.TlsCertificateVerify (certificate-verify (& verify-bytes))]
    [finished-bytes : byte_buf.ByteBuf (flight-message hex (+ first 1))]
    (begin
      (test.assert-i64-eq verify.algorithm algorithm (clone message))
      (test.assert-i64-eq
        (byte_buf.len (& verify.signature))
        signature-length
        (clone message))
      (assert-buf
        (tls.encode-certificate-verify (byte_buf.new) (& verify))
        (view (& verify-bytes))
        (clone message))
      (match (tls.decode-finished (body-of (& finished-bytes)) 32)
        [(TlsBytesOk verify-data)
          (assert-buf
            (tls.encode-finished (byte_buf.new) (view (& verify-data)))
            (view (& finished-bytes))
            (clone message))]
        [(TlsBytesErr _) (test.assert-true false (clone message))]))))

(define (server-flight-vectors) : unit
  (let
    [ee-bytes : byte_buf.ByteBuf (flight-message (s3-server-flight) 0)]
    [ee : (__tl_dyn-array tls.TlsExtension) (encrypted-extensions (& ee-bytes))]
    [ee4-bytes : byte_buf.ByteBuf (hex-bytes (s4-ee))]
    [ee4 : (__tl_dyn-array tls.TlsExtension)
      (encrypted-extensions (& ee4-bytes))]
    [ch : byte_buf.ByteBuf (record-message (s3-ch-record))]
    [offered : tls.TlsClientHello (client-hello (& ch))]
    [cr-bytes : byte_buf.ByteBuf (hex-bytes (s6-cr))]
    [nst-bytes : byte_buf.ByteBuf (hex-bytes (s3-nst))]
    (begin
      (assert-buf-hex
        (extension-types (& ee))
        "000a001c0000"
        "EncryptedExtensions types")
      (expect-check-ok
        (tls.decode-empty-extension
          (extension-of (& ee) tls.extension-server-name))
        "server_name acknowledgement")
      (test.assert-owned-string-eq
        (codes
          (tls.decode-supported-groups
            (extension-of (& ee) tls.extension-supported-groups)
            (& wire-limits)))
        "001d00170018001901000101010201030104"
        "server supported_groups")
      (assert-buf
        (tls.encode-encrypted-extensions (byte_buf.new) (& ee))
        (view (& ee-bytes))
        "EncryptedExtensions re-encodes")
      (assert-buf
        (tls.encode-encrypted-extensions (byte_buf.new) (& ee4))
        (view (& ee4-bytes))
        "section 4 EncryptedExtensions re-encodes")
      (expect-check-ok
        (check-offered
          (& ee)
          (& offered.extensions)
          tls.context-encrypted-extensions)
        "EncryptedExtensions answers offered extensions")
      (expect-check-error
        (check-offered
          (& ee4)
          (& offered.extensions)
          tls.context-encrypted-extensions)
        tls.error-unsolicited-extension
        3
        tls.alert-unsupported-extension
        "early_data the ClientHello did not offer")
      (check-certificate-message
        (s3-server-flight)
        1
        432
        "section 3 server Certificate")
      (check-certificate-message
        (s6-server-flight)
        2
        306
        "section 6 server Certificate")
      (check-certificate-message
        (s6-client-flight)
        0
        438
        "section 6 client Certificate")
      (check-verify-and-finished
        (s3-server-flight)
        2
        0x0804
        128
        "section 3 server CertificateVerify and Finished")
      (check-verify-and-finished
        (s6-server-flight)
        3
        0x0403
        71
        "section 6 ECDSA CertificateVerify and Finished")
      (check-verify-and-finished
        (s6-client-flight)
        1
        0x0804
        128
        "section 6 client CertificateVerify and Finished")
      (let
        [finished : byte_buf.ByteBuf (hex-bytes (s3-client-finished))]
        (begin
          (test.assert-owned-string-eq
            (bytes-hex (tls.decode-finished (body-of (& finished)) 32))
            "a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61"
            "client verify_data")
          (test.assert-owned-string-eq
            (bytes-hex (tls.decode-finished (body-of (& finished)) 48))
            "truncated"
            "a SHA-384 Finished is longer")
          (test.assert-owned-string-eq
            (bytes-hex (tls.decode-finished (body-of (& finished)) 16))
            "trailing bytes"
            "a shorter hash leaves bytes")))
      (match (tls.decode-certificate-request
        (body-of (& cr-bytes))
        (& wire-limits))
        [(TlsCertificateRequestOk request)
          (begin
            (test.assert-i64-eq
              (byte_buf.len (& request.context))
              0
              "in-handshake request context")
            (assert-buf-hex
              (extension-types (& request.extensions))
              "000d"
              "CertificateRequest extensions")
            (test.assert-owned-string-eq
              (codes
                (tls.decode-signature-schemes
                  (extension-of
                    (& request.extensions)
                    tls.extension-signature-algorithms)
                  (& wire-limits)))
              "040305030603020308040805080604010501060102010402050206020202"
              "requested signature algorithms")
            (assert-buf
              (tls.encode-certificate-request (byte_buf.new) (& request))
              (view (& cr-bytes))
              "CertificateRequest re-encodes")
            (assert-buf
              (flight-message (s6-server-flight) 1)
              (view (& cr-bytes))
              "the flight carries the same CertificateRequest"))]
        [_ (test.assert-true false "CertificateRequest decodes")])
      (match (tls.decode-new-session-ticket
        (body-of (& nst-bytes))
        (& wire-limits))
        [(TlsNewSessionTicketOk ticket)
          (begin
            (test.assert-i64-eq ticket.lifetime 30 "ticket_lifetime")
            (test.assert-i64-eq ticket.age-add 0xfad6aac5 "ticket_age_add")
            (assert-hex (view (& ticket.nonce)) "0000" "ticket_nonce")
            (test.assert-i64-eq (byte_buf.len (& ticket.ticket)) 178 "ticket")
            (test.assert-i64-eq
              (code
                (tls.decode-early-data-ticket
                  (extension-of (& ticket.extensions) tls.extension-early-data)))
              1024
              "max_early_data_size")
            (assert-buf
              (tls.encode-new-session-ticket (byte_buf.new) (& ticket))
              (view (& nst-bytes))
              "NewSessionTicket re-encodes"))]
        [_ (test.assert-true false "NewSessionTicket decodes")])
      (let
        [eoed : byte_buf.ByteBuf (hex-bytes (s4-eoed))]
        (begin
          (expect-check-ok
            (tls.decode-end-of-early-data (body-of (& eoed)))
            "EndOfEarlyData")
          (assert-buf
            (tls.encode-end-of-early-data (byte_buf.new))
            (view (& eoed))
            "EndOfEarlyData re-encodes")))
      (let
        [empty : tls.TlsCertificate
          (tls.TlsCertificate
            (byte_buf.new)
            (__tl_make-array tls.TlsCertificateEntry 0))]
        [encoded : byte_buf.ByteBuf
          (tls.encode-certificate (byte_buf.new) (& empty))]
        (begin
          (assert-hex
            (view (& encoded))
            "0b00000400000000"
            "an empty client Certificate")
          (test.assert-i64-eq
            (array-length (certificate (& encoded)).entries)
            0
            "an empty Certificate decodes"))))))

;; --- extension blocks ------------------------------------------------------------------
(define (expect-block-error
  [hex : String]
  [context : i64]
  [block-limits : tls.TlsWireLimits]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (let
    [block : byte_buf.ByteBuf (hex-bytes hex)]
    (match (tls.decode-extension-block
      (view (& block))
      context
      (& block-limits))
      [(TlsExtensionsErr error)
        (assert-error (& error) code offset alert (clone message))]
      [(TlsExtensionsOk _) (test.assert-true false (clone message))])))

(define (expect-block-types
  [hex : String]
  [context : i64]
  [block-limits : tls.TlsWireLimits]
  [types : String]
  [message : String]) : unit
  (let
    [block : byte_buf.ByteBuf (hex-bytes hex)]
    (match (tls.decode-extension-block
      (view (& block))
      context
      (& block-limits))
      [(TlsExtensionsOk extensions)
        (begin
          (assert-buf-hex
            (extension-types (& extensions))
            types
            (clone message))
          (let
            [encoded : byte_buf.ByteBuf
              (tls.encode-extensions (byte_buf.new) (& extensions))]
            (assert-same (view (& encoded)) (view (& block)) (clone message))))]
      [(TlsExtensionsErr error)
        (test.assert-owned-string-eq
          (tls.error-name error.code)
          "none"
          (clone message))])))

(define (extension-block-rules) : unit
  (let
    [three : tls.TlsWireLimits (limits-with 16384 262144 3 1024 16 65536)]
    [ch : i64 tls.context-client-hello]
    [sh : i64 tls.context-server-hello]
    [hrr : i64 tls.context-hello-retry-request]
    [ee : i64 tls.context-encrypted-extensions]
    [ct : i64 tls.context-certificate]
    [cr : i64 tls.context-certificate-request]
    [nst : i64 tls.context-new-session-ticket]
    (begin
      (expect-block-types "0000" ee (limits) "" "an empty block")
      (expect-block-types
        "0008000a0000000d0000"
        ch
        (limits)
        "000a000d"
        "two extensions")
      (expect-block-error
        "0008000a0000000a0000"
        ch
        (limits)
        tls.error-duplicate-extension
        6
        tls.alert-illegal-parameter
        "a repeated type")
      (expect-block-error
        "000c12340000000a000012340000"
        ch
        (limits)
        tls.error-duplicate-extension
        10
        tls.alert-illegal-parameter
        "a repeated unknown type")
      (expect-block-error
        "0006002b00020304"
        ee
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "supported_versions in EncryptedExtensions")
      (expect-block-error
        "000400330000"
        nst
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "key_share in NewSessionTicket")
      (expect-block-error
        "0004002c0000"
        sh
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "cookie in ServerHello")
      (expect-block-error
        "0004002a0000"
        cr
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "early_data in CertificateRequest")
      (expect-block-error
        "0004000d0000"
        ct
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "signature_algorithms in a certificate entry")
      (expect-block-error
        "000400310000"
        ee
        (limits)
        tls.error-extension-context
        2
        tls.alert-illegal-parameter
        "post_handshake_auth in EncryptedExtensions")
      (expect-block-types
        "0004002c0000"
        hrr
        (limits)
        "002c"
        "cookie in HelloRetryRequest")
      (expect-block-types
        "000400050000"
        ct
        (limits)
        "0005"
        "status_request in a certificate entry")
      (expect-block-types
        "000400300000"
        cr
        (limits)
        "0030"
        "oid_filters in CertificateRequest")
      (expect-block-types
        "0004002a0000"
        nst
        (limits)
        "002a"
        "early_data in NewSessionTicket")
      (expect-block-types
        "0006123400021122"
        ch
        (limits)
        "1234"
        "unknown extensions are kept in ClientHello")
      (expect-block-types
        "000412340000"
        cr
        (limits)
        "1234"
        "unknown extensions are kept in CertificateRequest")
      (expect-block-types
        "000412340000"
        nst
        (limits)
        "1234"
        "unknown extensions are kept in NewSessionTicket")
      (expect-block-error
        "000412340000"
        sh
        (limits)
        tls.error-unsolicited-extension
        2
        tls.alert-unsupported-extension
        "unknown extension in ServerHello")
      (expect-block-error
        "000412340000"
        hrr
        (limits)
        tls.error-unsolicited-extension
        2
        tls.alert-unsupported-extension
        "unknown extension in HelloRetryRequest")
      (expect-block-error
        "000412340000"
        ee
        (limits)
        tls.error-unsolicited-extension
        2
        tls.alert-unsupported-extension
        "unknown extension in EncryptedExtensions")
      (expect-block-error
        "000412340000"
        ct
        (limits)
        tls.error-unsolicited-extension
        2
        tls.alert-unsupported-extension
        "unknown extension in a certificate entry")
      (expect-block-error
        "000800290000000a0000"
        ch
        (limits)
        tls.error-psk-not-last
        2
        tls.alert-illegal-parameter
        "pre_shared_key before another extension")
      (expect-block-types
        "0008000a000000290000"
        ch
        (limits)
        "000a0029"
        "pre_shared_key last")
      (expect-block-types
        "000a00290002000000330000"
        sh
        (limits)
        "00290033"
        "pre_shared_key anywhere in ServerHello")
      (expect-block-types
        "000c010000000101000001020000"
        ch
        three
        "010001010102"
        "three extensions at a limit of three")
      (expect-block-error
        "001001000000010100000102000001030000"
        ch
        three
        tls.error-too-many-extensions
        14
        tls.alert-decode-error
        "a fourth extension")
      (expect-block-error
        "0003000a00"
        ch
        (limits)
        tls.error-truncated
        2
        tls.alert-decode-error
        "a partial extension header")
      (expect-block-error
        "0004000a0001"
        ch
        (limits)
        tls.error-truncated
        4
        tls.alert-decode-error
        "extension data past its block")
      (expect-block-error
        "0005000a0000"
        ch
        (limits)
        tls.error-truncated
        0
        tls.alert-decode-error
        "a block past its message")
      (expect-block-error
        "0004000a000000"
        ch
        (limits)
        tls.error-trailing
        6
        tls.alert-decode-error
        "bytes after the block")
      (expect-block-error
        "00"
        ch
        (limits)
        tls.error-truncated
        0
        tls.alert-decode-error
        "a one-byte block")
      (expect-block-error
        ""
        ch
        (limits)
        tls.error-truncated
        0
        tls.alert-decode-error
        "no block"))))

;; --- extension bodies -----------------------------------------------------------------
(define (expect-codes-error
  [result : tls.TlsCodesResult]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (match result
    [(TlsCodesErr error)
      (assert-error
        (& error)
        code
        offset
        tls.alert-decode-error
        (clone message))]
    [(TlsCodesOk _) (test.assert-true false (clone message))]))

(define (expect-bytes-error
  [result : tls.TlsBytesResult]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (match result
    [(TlsBytesErr error)
      (assert-error (& error) code offset alert (clone message))]
    [(TlsBytesOk _) (test.assert-true false (clone message))]))

(define (expect-list-error
  [result : tls.TlsBytesListResult]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (match result
    [(TlsBytesListErr error)
      (assert-error
        (& error)
        code
        offset
        tls.alert-decode-error
        (clone message))]
    [(TlsBytesListOk _) (test.assert-true false (clone message))]))

(define (expect-shares-error
  [result : tls.TlsKeySharesResult]
  [code : i64]
  [offset : i64]
  [alert : i64]
  [message : String]) : unit
  (match result
    [(TlsKeySharesErr error)
      (assert-error (& error) code offset alert (clone message))]
    [(TlsKeySharesOk _) (test.assert-true false (clone message))]))

(define (list-hex [result : tls.TlsBytesListResult]) : String
  (match result
    [(TlsBytesListOk items)
      (let
        [out : byte_buf.ByteBuf (byte_buf.new)]
        [index : i64 0]
        (begin
          (while (< index (array-length items))
            (begin
              (set!
                out
                (tls.encode-opaque out (view (& (array-ref items index))) 1))
              (set! index (+ index 1))))
          (hex-string (view (& out)))))]
    [(TlsBytesListErr error) (tls.error-name error.code)]))

(define (extension-bodies) : unit
  (let
    [one : tls.TlsWireLimits (limits-with 16384 262144 64 1 16 65536)]
    [d : byte_buf.ByteBuf (byte_buf.new)]
    (begin
      (set! d (hex-bytes "0303040303"))
      (expect-codes-error
        (tls.decode-supported-versions (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "an odd version list")
      (set! d (hex-bytes "02030400"))
      (expect-codes-error
        (tls.decode-supported-versions (view (& d)) (& wire-limits))
        tls.error-trailing
        3
        "bytes after the version list")
      (set! d (hex-bytes "00"))
      (expect-codes-error
        (tls.decode-supported-versions (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "an empty version list")
      (set! d (hex-bytes "040304"))
      (expect-codes-error
        (tls.decode-supported-versions (view (& d)) (& wire-limits))
        tls.error-truncated
        0
        "a version list past its data")
      (set! d (hex-bytes "0403040303"))
      (test.assert-owned-string-eq
        (codes (tls.decode-supported-versions (view (& d)) (& wire-limits)))
        "03040303"
        "two versions")
      (expect-codes-error
        (tls.decode-supported-versions (view (& d)) (& one))
        tls.error-too-many-entries
        0
        "two versions at a limit of one")
      (set! d (hex-bytes "030400"))
      (test.assert-i64-eq
        (code (tls.decode-selected-version (view (& d))))
        (- 0 tls.error-trailing)
        "a three-byte selected version")
      (set! d (hex-bytes "03"))
      (test.assert-i64-eq
        (code (tls.decode-selected-version (view (& d))))
        (- 0 tls.error-truncated)
        "a one-byte selected version")
      (set! d (hex-bytes "000100"))
      (expect-codes-error
        (tls.decode-supported-groups (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "a one-byte group list")
      (set! d (hex-bytes "0000"))
      (expect-codes-error
        (tls.decode-signature-schemes (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "an empty scheme list")
      (set! d (hex-bytes "ffff"))
      (expect-codes-error
        (tls.decode-signature-schemes (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "a scheme list over 2^16-2")
      (set! d (hex-bytes "00"))
      (expect-codes-error
        (tls.decode-psk-key-exchange-modes (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "no psk modes")
      (set! d (hex-bytes "00000400"))
      (test.assert-i64-eq
        (code (tls.decode-early-data-ticket (view (& d))))
        1024
        "max_early_data_size")
      (set! d (hex-bytes "000004"))
      (test.assert-i64-eq
        (code (tls.decode-early-data-ticket (view (& d))))
        (- 0 tls.error-truncated)
        "a short max_early_data_size")
      (set! d (hex-bytes "0000"))
      (match (tls.decode-key-share-client-hello (view (& d)) (& wire-limits))
        [(TlsKeySharesOk shares)
          (test.assert-i64-eq
            (array-length shares)
            0
            "an empty share list asks for HelloRetryRequest")]
        [_ (test.assert-true false "an empty share list is legal")])
      (set! d (hex-bytes "000a00170001aa00170001bb"))
      (expect-shares-error
        (tls.decode-key-share-client-hello (view (& d)) (& wire-limits))
        tls.error-duplicate-entry
        7
        tls.alert-illegal-parameter
        "a repeated group")
      (set! d (hex-bytes "000a00170001aa001d0001bb"))
      (expect-shares-error
        (tls.decode-key-share-client-hello (view (& d)) (& one))
        tls.error-too-many-entries
        7
        tls.alert-decode-error
        "two shares at a limit of one")
      (set! d (hex-bytes "000400170000"))
      (expect-shares-error
        (tls.decode-key-share-client-hello (view (& d)) (& wire-limits))
        tls.error-length-range
        4
        tls.alert-decode-error
        "an empty key_exchange")
      (set! d (hex-bytes "000500170005aa"))
      (expect-shares-error
        (tls.decode-key-share-client-hello (view (& d)) (& wire-limits))
        tls.error-truncated
        4
        tls.alert-decode-error
        "a key_exchange past its list")
      (set! d (hex-bytes "001700010000"))
      (match (tls.decode-key-share-server-hello (view (& d)))
        [(TlsKeyShareErr error)
          (assert-error
            (& error)
            tls.error-trailing
            5
            tls.alert-decode-error
            "bytes after the server share")]
        [_ (test.assert-true false "bytes after the server share")])
      (set! d (hex-bytes "00170000"))
      (match (tls.decode-key-share-server-hello (view (& d)))
        [(TlsKeyShareErr error)
          (assert-error
            (& error)
            tls.error-length-range
            2
            tls.alert-decode-error
            "an empty server key_exchange")]
        [_ (test.assert-true false "an empty server key_exchange")])
      (set! d (hex-bytes "0009010006736572766572"))
      (expect-bytes-error
        (tls.decode-server-name (view (& d)))
        tls.error-illegal-value
        2
        tls.alert-illegal-parameter
        "a name type other than host_name")
      (set! d (hex-bytes "0012000006736572766572000006736572766572"))
      (expect-bytes-error
        (tls.decode-server-name (view (& d)))
        tls.error-duplicate-entry
        11
        tls.alert-illegal-parameter
        "two host names")
      (set! d (hex-bytes "000c00000673657276657201aabb"))
      (expect-bytes-error
        (tls.decode-server-name (view (& d)))
        tls.error-illegal-value
        11
        tls.alert-illegal-parameter
        "another name type after the host name")
      (set! d (hex-bytes "0000"))
      (expect-bytes-error
        (tls.decode-server-name (view (& d)))
        tls.error-length-range
        0
        tls.alert-decode-error
        "an empty server name list")
      (set! d (hex-bytes "0003000000"))
      (expect-bytes-error
        (tls.decode-server-name (view (& d)))
        tls.error-length-range
        3
        tls.alert-decode-error
        "an empty host name")
      (set! d (hex-bytes "000c02683208687474702f312e31"))
      (test.assert-owned-string-eq
        (list-hex (tls.decode-alpn-list (view (& d)) (& wire-limits)))
        "02683208687474702f312e31"
        "two protocol names")
      (expect-list-error
        (tls.decode-alpn-list (view (& d)) (& one))
        tls.error-too-many-entries
        5
        "two names at a limit of one")
      (set! d (hex-bytes "0000"))
      (expect-list-error
        (tls.decode-alpn-list (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "an empty protocol list")
      (set! d (hex-bytes "0003000168"))
      (expect-list-error
        (tls.decode-alpn-list (view (& d)) (& wire-limits))
        tls.error-length-range
        2
        "an empty protocol name")
      (set! d (hex-bytes "0003026832"))
      (test.assert-owned-string-eq
        (bytes-hex (tls.decode-alpn-selected (view (& d))))
        "6832"
        "the selected protocol")
      (set! d (hex-bytes "00050268320178"))
      (expect-bytes-error
        (tls.decode-alpn-selected (view (& d)))
        tls.error-illegal-value
        5
        tls.alert-illegal-parameter
        "two selected protocols")
      (set! d (hex-bytes "0000"))
      (expect-bytes-error
        (tls.decode-cookie (view (& d)))
        tls.error-length-range
        0
        tls.alert-decode-error
        "an empty cookie")
      (set! d (hex-bytes "00"))
      (expect-check-error
        (tls.decode-empty-extension (view (& d)))
        tls.error-trailing
        0
        tls.alert-decode-error
        "data in an empty extension")
      (set! d (hex-bytes "00020000"))
      (expect-list-error
        (tls.decode-certificate-authorities (view (& d)) (& wire-limits))
        tls.error-length-range
        0
        "an authorities list under three bytes")
      (set! d (hex-bytes "000400003030"))
      (expect-list-error
        (tls.decode-certificate-authorities (view (& d)) (& wire-limits))
        tls.error-length-range
        2
        "an empty distinguished name")
      (set! d (hex-bytes "0003000130"))
      (test.assert-owned-string-eq
        (list-hex
          (tls.decode-certificate-authorities (view (& d)) (& wire-limits)))
        "0130"
        "one distinguished name"))))

;: RFC 9846 table 1, typed out independently of the module: the messages each
;: extension may appear in, as CH 1, SH 2, HRR 4, EE 8, CT 16, CR 32, NST 64.
;: `max_fragment_length` and `signed_certificate_timestamp` keep their IANA
;: TLS 1.3 contexts although the table lists only recommended extensions.
(define (table-contexts [ext-type : i64]) : i64
  (cond
    [(= ext-type 0) (+ 1 (+ 8 32))]
    [(= ext-type 1) (+ 1 8)]
    [(= ext-type 5) (+ 1 (+ 32 16))]
    [(= ext-type 10) (+ 1 8)]
    [(= ext-type 13) (+ 1 32)]
    [(= ext-type 14) (+ 1 8)]
    [(= ext-type 15) (+ 1 8)]
    [(= ext-type 16) (+ 1 8)]
    [(= ext-type 18) (+ 1 (+ 32 16))]
    [(= ext-type 19) (+ 1 8)]
    [(= ext-type 20) (+ 1 8)]
    [(= ext-type 21) 1]
    [(= ext-type 27) (+ 1 32)]
    [(= ext-type 28) (+ 1 8)]
    [(= ext-type 34) (+ 1 (+ 32 16))]
    [(= ext-type 39) (+ 1 8)]
    [(= ext-type 41) (+ 1 2)]
    [(= ext-type 42) (+ 1 (+ 8 64))]
    [(= ext-type 43) (+ 1 (+ 2 4))]
    [(= ext-type 44) (+ 1 4)]
    [(= ext-type 45) 1]
    [(= ext-type 47) (+ 1 32)]
    [(= ext-type 48) 32]
    [(= ext-type 49) 1]
    [(= ext-type 50) (+ 1 32)]
    [(= ext-type 51) (+ 1 (+ 2 4))]
    [(= ext-type 52) (+ 1 (+ 32 16))]
    [(= ext-type 55) (+ 1 8)]
    [(= ext-type 56) (+ 1 8)]
    [(= ext-type 57) (+ 1 8)]
    [(= ext-type 58) (+ 1 8)]
    [(= ext-type 0xfd00) 1]
    [(= ext-type 0xfe0d) (+ 1 (+ 4 8))]
    [else 0]))

;: Decode a one-extension block of every type in every context and compare
;: the outcome with the table.
(define (extension-context-table) : unit
  (let
    [contexts : (__tl_dyn-array i64) (__tl_make-array i64 7)]
    [bits : (__tl_dyn-array i64) (__tl_make-array i64 7)]
    [block : byte_buf.ByteBuf (hex-bytes "000400000000")]
    [ext-type : i64 0]
    [recognized : i64 0]
    (begin
      (set! (array-ref contexts 0) tls.context-client-hello)
      (set! (array-ref contexts 1) tls.context-server-hello)
      (set! (array-ref contexts 2) tls.context-hello-retry-request)
      (set! (array-ref contexts 3) tls.context-encrypted-extensions)
      (set! (array-ref contexts 4) tls.context-certificate)
      (set! (array-ref contexts 5) tls.context-certificate-request)
      (set! (array-ref contexts 6) tls.context-new-session-ticket)
      (set! (array-ref bits 0) 1)
      (set! (array-ref bits 1) 2)
      (set! (array-ref bits 2) 4)
      (set! (array-ref bits 3) 8)
      (set! (array-ref bits 4) 16)
      (set! (array-ref bits 5) 32)
      (set! (array-ref bits 6) 64)
      (while (< ext-type 65536)
        (let
          [allowed : i64 (table-contexts ext-type)]
          [index : i64 0]
          (begin
            (set! block (byte_buf.set! block 2 (cast (/ ext-type 256) : u8)))
            (set! block (byte_buf.set! block 3 (cast (% ext-type 256) : u8)))
            (test.assert-bool-eq
              (tls.extension-recognized? ext-type)
              (!= allowed 0)
              "recognized extension types")
            (when (!= allowed 0) (set! recognized (+ recognized 1)))
            (while (< index 7)
              (let
                [context : i64 (array-ref contexts index)]
                [response : bool
                  (or (= index 1) (= index 2) (= index 3) (= index 4))]
                [expected : i64
                  (cond
                    [(!= (bit-and allowed (array-ref bits index)) 0) 0]
                    [(!= allowed 0) tls.error-extension-context]
                    [response tls.error-unsolicited-extension]
                    [else 0])]
                (begin
                  (match (tls.decode-extension-block
                    (view (& block))
                    context
                    (& wire-limits))
                    [(TlsExtensionsOk _)
                      (test.assert-i64-eq 0 expected "table: allowed")]
                    [(TlsExtensionsErr error)
                      (begin
                        (test.assert-i64-eq
                          error.code
                          expected
                          "table: rejected")
                        (test.assert-i64-eq error.offset 2 "table: offset"))])
                  (set! index (+ index 1)))))
            (set! ext-type (+ ext-type 1)))))
      (test.assert-i64-eq recognized 33 "recognized extension count"))))

;; --- malformed messages -----------------------------------------------------------------
(define (end-of-early-data-of [hex : String]) : tls.TlsWireCheck
  (let
    [body : byte_buf.ByteBuf (hex-bytes hex)]
    (tls.decode-end-of-early-data (view (& body)))))

(define (alert-of [hex : String]) : tls.TlsAlertResult
  (let
    [content : byte_buf.ByteBuf (hex-bytes hex)]
    (tls.decode-alert (view (& content)))))

(define (valid-limits? [candidate : tls.TlsWireLimits]) : bool
  (tls.limits-valid? (& candidate)))

;: Decode `body` as a message of `msg-type`, returning the error code or 0.
;: Every error offset must lie inside the body.
(define (decode-status
  [msg-type : i64]
  [body : (& body bytes)]
  [decode-limits : (& decode-limits tls.TlsWireLimits)]) : i64
  (let
    [error : tls.TlsWireError (tls.TlsWireError 0 0 0)]
    (begin
      (cond
        [(= msg-type tls.handshake-client-hello)
          (match (tls.decode-client-hello body decode-limits)
            [(TlsClientHelloErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-server-hello)
          (match (tls.decode-server-hello body decode-limits)
            [(TlsServerHelloErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-encrypted-extensions)
          (match (tls.decode-encrypted-extensions body decode-limits)
            [(TlsExtensionsErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-certificate-request)
          (match (tls.decode-certificate-request body decode-limits)
            [(TlsCertificateRequestErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-certificate)
          (match (tls.decode-certificate body decode-limits)
            [(TlsCertificateErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-certificate-verify)
          (match (tls.decode-certificate-verify body)
            [(TlsCertificateVerifyErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-finished)
          (match (tls.decode-finished body 32)
            [(TlsBytesErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-new-session-ticket)
          (match (tls.decode-new-session-ticket body decode-limits)
            [(TlsNewSessionTicketErr found) (set! error found)]
            [_ unit])]
        [(= msg-type tls.handshake-key-update)
          (match (tls.decode-key-update body)
            [(TlsCodeErr found) (set! error found)]
            [_ unit])]
        [else (test.assert-true false "known message type")])
      (when
        (!= error.code 0)
        (begin
          (test.assert-true
            (and
              (>= error.offset 0)
              (<= error.offset (byte_buf.bytes-length body)))
            "error offsets lie inside the message")
          (test.assert-true
            (or
              (= error.alert tls.alert-decode-error)
              (= error.alert tls.alert-illegal-parameter)
              (= error.alert tls.alert-unsupported-extension)
              (= error.alert tls.alert-missing-extension))
            "decode failures carry a decode alert")))
      error.code)))

(define (expect-message-error
  [msg-type : i64]
  [hex : String]
  [decode-limits : tls.TlsWireLimits]
  [code : i64]
  [message : String]) : unit
  (let
    [body : byte_buf.ByteBuf (hex-bytes hex)]
    (test.assert-owned-string-eq
      (tls.error-name
        (decode-status msg-type (view (& body)) (& decode-limits)))
      (tls.error-name code)
      (clone message))))

;: Every strict prefix of every message vector fails, and every single-byte
;: change either decodes or fails inside the message.
(define (message-corpus [msg-type : i64] [message : byte_buf.ByteBuf]) : unit
  (let
    [body : (& message bytes) (body-of (& message))]
    [length : i64 (byte_buf.bytes-length body)]
    [cut : i64 0]
    [index : i64 0]
    (begin
      (test.assert-i64-eq
        (decode-status msg-type body (& wire-limits))
        0
        "the vector itself decodes")
      (while (< cut length)
        (begin
          (test.assert-true
            (!=
              (decode-status
                msg-type
                (byte_buf.bytes-slice-view body 0 cut)
                (& wire-limits))
              0)
            "a truncated message fails")
          (set! cut (+ cut 1))))
      (while (< index length)
        (let
          [changed : byte_buf.ByteBuf (byte_buf.from-bytes body)]
          [flip : i64 (+ 1 (% (* index 37) 255))]
          (begin
            (set!
              changed
              (byte_buf.set!
                changed
                index
                (cast
                  (bit-xor (cast (byte_buf.bytes-ref body index) : i64) flip)
                  : u8)))
            (decode-status msg-type (view (& changed)) (& wire-limits))
            (set! index (+ index 1))))))))

(define (malformed-messages) : unit
  (let
    [one-cert : tls.TlsWireLimits (limits-with 16384 262144 64 1024 1 65536)]
    [tiny-cert : tls.TlsWireLimits (limits-with 16384 262144 64 1024 16 1)]
    (begin
      (message-corpus
        tls.handshake-client-hello
        (record-message (s3-ch-record)))
      (message-corpus tls.handshake-client-hello (hex-bytes (s4-ch)))
      (message-corpus
        tls.handshake-server-hello
        (record-message (s3-sh-record)))
      (message-corpus tls.handshake-server-hello (hex-bytes (s5-hrr)))
      (message-corpus
        tls.handshake-encrypted-extensions
        (flight-message (s3-server-flight) 0))
      (message-corpus tls.handshake-certificate-request (hex-bytes (s6-cr)))
      (message-corpus
        tls.handshake-certificate
        (flight-message (s6-server-flight) 2))
      (message-corpus
        tls.handshake-certificate-verify
        (flight-message (s6-server-flight) 3))
      (message-corpus tls.handshake-finished (hex-bytes (s3-client-finished)))
      (message-corpus tls.handshake-new-session-ticket (hex-bytes (s3-nst)))
      (let
        [ch : byte_buf.ByteBuf (record-message (s3-ch-record))]
        [body : byte_buf.ByteBuf (byte_buf.from-bytes (body-of (& ch)))]
        [bad-compression : byte_buf.ByteBuf
          (byte_buf.set! (byte_buf.from-bytes (view (& body))) 44 1)]
        (begin
          (test.assert-i64-eq
            (cast (byte_buf.ref (& body) 43) : i64)
            1
            "one compression method")
          (expect-message-error
            1
            (hex-of (byte_buf.set! (byte_buf.from-bytes (view (& body))) 44 1))
            (limits)
            tls.error-illegal-value
            "compression method 1")
          (expect-message-error
            1
            (hex-of (byte_buf.set! (byte_buf.from-bytes (view (& body))) 34 33))
            (limits)
            tls.error-length-range
            "a 33-byte session id")
          (expect-message-error
            1
            (hex-of (byte_buf.push (byte_buf.from-bytes (view (& body))) 0))
            (limits)
            tls.error-trailing
            "a byte after the ClientHello")
          (expect-message-error
            1
            (hex-of (byte_buf.set! (byte_buf.from-bytes (view (& body))) 36 7))
            (limits)
            tls.error-length-range
            "an odd cipher suite list")
          (expect-message-error
            1
            (hex-string (view (& body)))
            (limits-with 16384 262144 64 2 16 65536)
            tls.error-too-many-entries
            "three suites at a limit of two")
          (test.assert-i64-eq
            (match (tls.decode-client-hello
              (view (& bad-compression))
              (& wire-limits))
              [(TlsClientHelloErr error) error.offset]
              [_ -1])
            43
            "the compression error offset")))
      (let
        [sh : byte_buf.ByteBuf (record-message (s3-sh-record))]
        [body : byte_buf.ByteBuf (byte_buf.from-bytes (body-of (& sh)))]
        [bad-compression : byte_buf.ByteBuf
          (byte_buf.set! (byte_buf.from-bytes (view (& body))) 37 1)]
        (begin
          (expect-message-error
            2
            (hex-of (byte_buf.set! (byte_buf.from-bytes (view (& body))) 37 1))
            (limits)
            tls.error-illegal-value
            "ServerHello compression method 1")
          (test.assert-i64-eq
            (match (tls.decode-server-hello
              (view (& bad-compression))
              (& wire-limits))
              [(TlsServerHelloErr error) error.offset]
              [_ -1])
            37
            "the ServerHello compression offset")))
      (expect-message-error 24 "00" (limits) 0 "update_not_requested")
      (expect-message-error 24 "01" (limits) 0 "update_requested")
      (expect-message-error
        24
        "02"
        (limits)
        tls.error-illegal-value
        "request_update 2")
      (expect-message-error
        24
        ""
        (limits)
        tls.error-truncated
        "an empty KeyUpdate")
      (expect-message-error
        24
        "0100"
        (limits)
        tls.error-trailing
        "a two-byte KeyUpdate")
      (expect-check-error
        (end-of-early-data-of "00")
        tls.error-trailing
        0
        tls.alert-decode-error
        "a non-empty EndOfEarlyData")
      (expect-message-error
        13
        "00000400300000"
        (limits)
        tls.error-missing-extension
        "CertificateRequest without signature_algorithms")
      (expect-message-error
        13
        "000000"
        (limits)
        tls.error-length-range
        "a CertificateRequest block under two bytes")
      (expect-message-error
        11
        "0000000c000001aa0000000001bb0000"
        one-cert
        tls.error-too-many-certificates
        "two certificates at a limit of one")
      (expect-message-error
        11
        "0000000c000001aa0000000001bb0000"
        (limits)
        0
        "two certificates")
      (expect-message-error
        11
        "00000007000002aabb0000"
        tiny-cert
        tls.error-certificate-too-large
        "a certificate over the byte limit")
      (expect-message-error
        11
        "000000050000000000"
        (limits)
        tls.error-length-range
        "an empty certificate")
      (expect-message-error
        11
        "0000000a000001aa000412340000"
        (limits)
        tls.error-unsolicited-extension
        "an unknown certificate extension")
      (expect-message-error
        11
        "0000000a000001aa000400050000"
        (limits)
        0
        "status_request on a certificate")
      (expect-message-error
        11
        "0000000a000001aa00040005"
        (limits)
        tls.error-truncated
        "a certificate list past the message")
      (expect-message-error
        11
        "01aa000000"
        (limits)
        0
        "a post-handshake request context")
      (expect-message-error
        4
        "0000001e0000000000000000000000"
        (limits)
        tls.error-length-range
        "an empty ticket")
      (expect-message-error
        15
        "0804008000"
        (limits)
        tls.error-truncated
        "a signature past the message")
      (expect-message-error
        15
        "08040000"
        (limits)
        0
        "an empty signature decodes"))))

(define (small-encoders) : unit
  (begin
    (assert-buf-hex
      (tls.encode-key-update (byte_buf.new) tls.key-update-requested)
      "1800000101"
      "KeyUpdate")
    (assert-buf-hex
      (tls.encode-alert
        (byte_buf.new)
        tls.alert-level-fatal
        tls.alert-decode-error)
      "0232"
      "alert")
    (assert-buf-hex
      (tls.encode-record-header (byte_buf.new) 23 0x0303 16640)
      "1703034100"
      "record header")
    (match (alert-of "0100")
      [(TlsAlertOk alert)
        (begin
          (test.assert-i64-eq alert.level 1 "close_notify level")
          (test.assert-i64-eq alert.description 0 "close_notify")
          (test.assert-false
            (tls.alert-fatal? alert.description)
            "close_notify is not an error"))]
      [_ (test.assert-true false "close_notify decodes")])
    (match (alert-of "02ff")
      [(TlsAlertOk alert)
        (test.assert-true
          (tls.alert-fatal? alert.description)
          "an unknown alert is an error")]
      [_ (test.assert-true false "unknown alerts decode")])
    (match (alert-of "015a")
      [(TlsAlertOk alert)
        (test.assert-false
          (tls.alert-fatal? alert.description)
          "user_canceled is not an error")]
      [_ (test.assert-true false "user_canceled decodes")])
    (match (alert-of "01")
      [(TlsAlertErr error)
        (assert-error
          (& error)
          tls.error-alert-length
          0
          tls.alert-decode-error
          "a one-byte alert")]
      [_ (test.assert-true false "a one-byte alert")])
    (test.assert-true (tls.limits-valid? (& wire-limits)) "default limits")
    (test.assert-false
      (valid-limits? (limits-with 0 262144 64 1024 16 65536))
      "zero record limit")
    (test.assert-false
      (valid-limits? (limits-with 16385 262144 64 1024 16 65536))
      "record limit over 2^14")
    (test.assert-false
      (valid-limits? (limits-with 16384 16777216 64 1024 16 65536))
      "message limit over 2^24-1")
    (test.assert-false
      (valid-limits? (limits-with 16384 262144 1025 1024 16 65536))
      "extension limit over 1024")
    (test.assert-false
      (valid-limits? (limits-with 16384 262144 64 1025 16 65536))
      "list limit over 1024")
    (test.assert-false
      (valid-limits? (limits-with 16384 262144 64 1024 0 65536))
      "zero certificates")
    (test.assert-owned-string-eq
      (tls.error-name 999)
      "unknown error"
      "unknown error names")
    (let
      [shares : (__tl_dyn-array tls.TlsKeyShareEntry)
        (__tl_make-array tls.TlsKeyShareEntry 2)]
      [host : String "example.test"]
      [names : (__tl_dyn-array byte_buf.ByteBuf)
        (__tl_make-array byte_buf.ByteBuf 2)]
      [versions : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [encoded-shares : byte_buf.ByteBuf (byte_buf.new)]
      (begin
        (set!
          (array-ref shares 0)
          (tls.TlsKeyShareEntry 0x17 (hex-bytes "04aabb")))
        (set! (array-ref shares 1) (tls.TlsKeyShareEntry 0x1d (hex-bytes "cc")))
        (set!
          encoded-shares
          (tls.encode-key-share-client-hello (byte_buf.new) (& shares)))
        (assert-buf-hex
          (tls.encode-key-share-client-hello (byte_buf.new) (& shares))
          "000c0017000304aabb001d0001cc"
          "ClientHello key_share")
        (match (tls.decode-key-share-client-hello
          (view (& encoded-shares))
          (& wire-limits))
          [(TlsKeySharesOk decoded)
            (test.assert-i64-eq (array-length decoded) 2 "shares round trip")]
          [_ (test.assert-true false "shares round trip")])
        (assert-buf-hex
          (tls.encode-server-name
            (byte_buf.new)
            (byte_buf.str-as-bytes (& host)))
          "000f00000c6578616d706c652e74657374"
          "server_name")
        (set! (array-ref names 0) (hex-bytes "6832"))
        (set! (array-ref names 1) (hex-bytes "687474702f312e31"))
        (assert-buf-hex
          (tls.encode-opaque-list (byte_buf.new) (& names) 2 1)
          "000c02683208687474702f312e31"
          "ALPN list")
        (set! (array-ref versions 0) tls.version-tls13)
        (assert-buf-hex
          (tls.encode-code-list (byte_buf.new) (& versions) 1 2)
          "020304"
          "supported_versions")))))

(define (main) : i64
  (begin
    (record-vector-headers)
    (record-splits)
    (record-header-errors)
    (record-partial-input)
    (record-reader-allocation)
    (inner-plaintext)
    (handshake-splits)
    (handshake-framing-rules)
    (handshake-size-limits)
    (handshake-reader-allocation)
    (fragmenting-encoder)
    (client-hello-vectors)
    (server-hello-vectors)
    (server-flight-vectors)
    (extension-block-rules)
    (extension-context-table)
    (extension-bodies)
    (malformed-messages)
    (small-encoders)
    42))