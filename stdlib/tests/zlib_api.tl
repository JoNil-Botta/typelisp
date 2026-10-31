(import stdlib.compress.zlib)
(import stdlib.compress.adler32)
(import stdlib.compress.deflate)
(import stdlib.byte_buf)
(import stdlib.test)
(import stdlib.iterator)
(import stdlib.profile)
(import stdlib.string)

(define (hex-value [value : i64]) : i64
  (if (<= value 57)
    (- value 48)
    (- value 87)))

(define (hex-bytes [hex : String]) : byte_buf.ByteBuf
  (let
    [view (byte_buf.str-as-bytes (& hex))]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (while (< index (byte_buf.bytes-length view))
      (let
        [high : i64 (hex-value (cast (byte_buf.bytes-ref view index) : i64))]
        [low : i64
          (hex-value (cast (byte_buf.bytes-ref view (+ index 1)) : i64))]
        (set! out (byte_buf.push out (cast (+ (* high 16) low) : u8)))
        (set! index (+ index 2))))
    out))

(define (repeat-byte [count : i64] [byte : u8]) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    (for [index (iterator.range 0 count)]
      (set! (array-ref slots index) byte))
    (byte_buf.from-array slots)))

;; Fixture order: 0 empty, 1 stored-hello, 2 fixed, 3 dynamic-level1, 4 dynamic-level4, 5 dynamic-level9, 6 cinfo1, 7 cinfo2, 8 cinfo3, 9 cinfo4, 10 cinfo5, 11 cinfo6, 12 cinfo7, 13 cinfo0-handmade, 14 preset-dictionary, 15 dictionary-edge-handmade, 16 ratio-pin-handmade.
(define (fixture-member [index : i64]) : String
  (cond
    [(= index 0) "789c030000000001"]
    [(= index 1) "7801010500faff68656c6c6f062c0215"]
    [(= index 2) "7801cb48cdc9c957c84022ab723293005f9f084e"]
    [(= index 3)
      "78011552cb11c45008ba5b05adf97bea8c15587d486636872c0882f74e55d1519b96e2d1cf90369b6ae1cfcda265c3d2ca47e1e9e2b8dbb9312b1b8c4686461ca1dd5d3df0584143b0fede8163a60c52150769b36cb19d597bb086db5efa996b6fa6dcbde7f31c1aef6982ffd4d69a71184135a132105d0245e7b6b30856f2b7ebb8453b69cfdef4f6eec52b01c66172b52ba51bda48f26cf79d501d05d3335ad3450c01e507caca8269049660aafde6cf009af1a9a091d0b12712cd8f56430b85ba014ecc9452e7b77e8c7735af258923401987641a997f6cd6b40dce7e01b830e8878532350bd335e7b0ca1caa9abd3d8a1601ac29e2cd3dbb1452d84b75fd25d57b9c4317e06fde22ab1f0b912eba4a8ab2d2bf55c845278a59c48e2d1c4d839ba2b8fe45ff12aa4596db6fa4049f2b6576175104dbef442b1583b3e34d302b86e8f6984ac544baf3c62ab206eced04ba3edc9e3b9220cd36796e1dc7868d8da74e82ddfc1e9caf629fe53c9b6c46c81b54b3bb0f03f5f2fc"]
    [(= index 4)
      "785e1552cb11c45008ba5b05adf97bea8c15587d486636872c0882f74e55d1519b96e2d1cf90369b6ae1cfcda265c3d2ca47e1e9e2b8dbb9312b1b8c4686461ca1dd5d3df0584143b0fede8163a60c52150769b36cb19d597bb086db5efa996b6fa6dcbde7f31c1aef6982ffd4d69a71184135a132105d0245e7b6b30856f2b7ebb8453b69cfdef4f6eec52b01c66172b52ba51bda48f26cf79d501d05d3335ad3450c01e507caca8269049660aafde6cf009af1a9a091d0b12712cd8f56430b85ba014ecc9452e7b77e8c7735af258923401987641a997f6cd6b40dce7e01b830e8878532350bd335e7b0ca1caa9abd3d8a1601ac29e2cd3dbb1452d84b75fd25d57b9c4317e06fde22ab1f0b912eba4a8ab2d2bf55c845278a59c48e2d1c4d839ba2b8fe45ff12aa4596db6fa4049f2bb53fda2882ed77a2958ac1d9f126981543747b4ca56222dd7963155903f676025d1f6ecf1d4990669b3cb78e63c3c6c65327c16e7e0fce57b1cf729e4d3623e40daad9dd0703f5f2fc"]
    [(= index 5)
      "78da1552cb11c45008ba5b05adf97bea8c15587d486636872c0882f74e55d1519b96e2d1cf90369b6ae1cfcda265c3d2ca47e1e9e2b8dbb9312b1b8c4686461ca1dd5d3df0584143b0fede8163a60c52150769b36cb19d597bb086db5efa996b6fa6dcbde7f31c1aef6982ffd4d69a71184135a132105d0245e7b6b30856f2b7ebb8453b69cfdef4f6eec52b01c66172b52ba51bda48f26cf79d501d05d3335ad3450c01e507caca8269049660aafde6cf009af1a9a091d0b12712cd8f56430b85ba014ecc9452e7b77e8c7735af258923401987641a997f6cd6b40dce7e01b830e8878532350bd335e7b0ca1caa9abd3d8a1601ac29e2cd3dbb1452d84b75fd25d57b9c4317e06fde22ab1f0b912eba4a8ab2d2bf55c845278a59c48e2d1c4d839ba2b8fe45ff12aa4596db6fa4049f2bb53fda2882ed77a2958ac1d9f126981543747b4ca56222dd7963155903f676025d1f6ecf1d4990669b3cb78e63c3c6c65327c16e7e0fce57b1cf729e4d3623e40daad9dd0703f5f2fc"]
    [(= index 6)
      "18952bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 7)
      "28912bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 8)
      "388d2bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 9)
      "48892bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 10)
      "58852bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 11)
      "68812bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 12)
      "789c2bcfcc4bc92f2f1f3124032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9d3d0075756fa1"]
    [(= index 13) "081d010300fcff616263024d0127"]
    [(= index 14) "78f9613c0ffa4366a3ab413302005d660ffa"]
    [(= index 15) "7820024d0127032200024d0127"]
    [else "7801731c050067f841c4"]))

(define (fixture-dictionary [index : i64]) : String
  (cond
    [(= index 0) ""]
    [(= index 1) ""]
    [(= index 2) ""]
    [(= index 3) ""]
    [(= index 4) ""]
    [(= index 5) ""]
    [(= index 6) ""]
    [(= index 7) ""]
    [(= index 8) ""]
    [(= index 9) ""]
    [(= index 10) ""]
    [(= index 11) ""]
    [(= index 12) ""]
    [(= index 13) ""]
    [(= index 14)
      "74686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f67"]
    [(= index 15) "616263"]
    [else ""]))

(define (fixture-output-hex [index : i64]) : String
  (cond
    [(= index 0) ""]
    [(= index 1) "68656c6c6f"]
    [(= index 2) "68656c6c6f2068656c6c6f2068656c6c6f207a6c6962"]
    [(= index 3) "text"]
    [(= index 4) "text"]
    [(= index 5) "text"]
    [(= index 6) "window"]
    [(= index 7) "window"]
    [(= index 8) "window"]
    [(= index 9) "window"]
    [(= index 10) "window"]
    [(= index 11) "window"]
    [(= index 12) "window"]
    [(= index 13) "616263"]
    [(= index 14)
      "746865206c617a7920646f67206a756d7073206f7665722074686520717569636b2062726f776e20666f78"]
    [(= index 15) "616263"]
    [else "ratio"]))

(define (text-hex) : String
  "7a667a616161206864676c6562650a6364686662206562696c65616264636663626264680a6c6462656267636961206365630a63207a7a6c697a6962626762692069616465646164647a6362626868686768692063646c0a2068200a206c6366667a20646366696762200a6767647a200a68626265680a626c69696c62662062682063626c7a65637a626361686c65650a7a7a6666636966632061646666616520637a62676c676c62626c63667a6263676964610a69200a616c7a7a660a61697a6c686567632061616263616c68677a6c6562686361652066626669686c686c6c7a6466670a2020696320620a7a676c6c0a67616c6461682065686567626c6c667a0a7a656320672062617a62626265616c2064696c646167637a206c676c0a6c2020656264206c6567620a6169686262657a622020626c63636967640a692064616962660a0a64682020626267696c68676720677a6920207a0a626261616c647a637a6c637a64676c6c61657a680a6520206220677a61200a670a6565620a0a646262686862686562682062657a66642020630a69612066206c2061676220626462616c62630a6262676565696363696262666c7a61696267206c2062696c646466697a66627a650a2066207a7a6c6768672063656367666620630a20207a2020207a69666c20656768660a206c0a68676261616564626264626564626562200a7a646865206767626c646c69626c206320686220676c650a61207a68626765656661652067680a0a6c6968626c64650a646464647a6761626c6c7a64646768622062206c2062616765612069207a627a62692067620a64696c636266682020676469646563636161206764656769206c7a7a7a0a20616c636965620a6c2061627a620a68616c7a61626468647a7a626362637a6265616965206c667a61207a686361207a672066626763680a626568680a6565630a6162627a7a")

(define (fixture-output [index : i64]) : byte_buf.ByteBuf
  (let
    [hex : String (fixture-output-hex index)]
    (cond
      [(string.eq hex "text") (hex-bytes (text-hex))]
      [(string.eq hex "ratio") (repeat-byte 259 (cast 65 : u8))]
      [(string.eq hex "window")
        (let
          [out : byte_buf.ByteBuf (byte_buf.new)]
          (for [step (iterator.range 0 40)]
            (set! out (byte_buf.append-string out "window")))
          (for [value (iterator.range 0 64)]
            (set! out (byte_buf.push out (cast value : u8))))
          out)]
      [else (hex-bytes hex)])))

(define (member-bytes [index : i64]) : byte_buf.ByteBuf
  (hex-bytes (fixture-member index)))

(define (dictionary-bytes [index : i64]) : byte_buf.ByteBuf
  (hex-bytes (fixture-dictionary index)))

;; Every fixture is followed by two container bytes that must stay unread.
(define (fixture-input [index : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push (member-bytes index) (cast 165 : u8))
    (cast 90 : u8)))

(define (kind-code [kind : (& kind zlib.ZlibErrorKind)]) : i64
  (match kind
    [(zlib.InvalidLimits) 0]
    [(zlib.InvalidState) 1]
    [(zlib.InvalidMethod) 2]
    [(zlib.InvalidWindow) 3]
    [(zlib.InvalidHeaderCheck) 4]
    [(zlib.DictionaryForbidden) 5]
    [(zlib.DictionaryRequired _) 6]
    [(zlib.DictionaryMismatch) 7]
    [(zlib.ChecksumMismatch) 8]
    [(zlib.MalformedBlock) 9]
    [(zlib.MalformedTree) 10]
    [(zlib.InvalidCode) 11]
    [(zlib.Truncated) 12]
    [(zlib.ReservedEncoding) 13]
    [(zlib.InvalidDistance) 14]
    [(zlib.Overflow) 15]
    [(zlib.InputLimit) 16]
    [(zlib.OutputLimit) 17]
    [(zlib.WindowLimit) 18]
    [(zlib.WorkLimit) 19]
    [(zlib.RatioLimit) 20]))

;; Done is -1, NeedDictionary -2, NeedInput -4 and NeedOutput -5.
(define (status-code [status : (& status zlib.ZlibStatus)]) : i64
  (match status
    [(zlib.Done) -1]
    [(zlib.NeedDictionary _) -2]
    [(zlib.NeedInput) -4]
    [(zlib.NeedOutput) -5]
    [(zlib.Error error) (kind-code (& error.kind))]))

;; A suspended or terminal call made again consumes, emits and charges nothing.
(define (assert-repeat
  [state : (&mut state zlib.Decoder)]
  [input : (& input bytes)]
  [output : (&mut output bytes)]
  [code : i64]) : unit
  (let
    [work : i64 (zlib.work-total state)]
    [again : zlib.ZlibStep (zlib.step! state input output true)]
    (test.assert-i64-eq again.consumed 0 "repeat consumes nothing")
    (test.assert-i64-eq again.produced 0 "repeat emits nothing")
    (test.assert-i64-eq (zlib.work-total state) work "repeat charges nothing")
    (test.assert-i64-eq (status-code (& again.status)) code "repeat status")))

;; Code -1 is Done, -2 a dictionary request left unanswered, else an error kind.
(defstruct Outcome
  (code i64)
  (id i64)
  (input i64)
  (output i64)
  (work i64))

(define (assert-same
  [actual : (& actual Outcome)]
  [expected : (& expected Outcome)]
  [label : String]) : unit
  (test.assert-i64-eq actual.code expected.code (clone label))
  (test.assert-i64-eq actual.id expected.id (clone label))
  (test.assert-i64-eq actual.input expected.input (clone label))
  (test.assert-i64-eq actual.output expected.output (clone label))
  (test.assert-i64-eq actual.work expected.work label))

(define (assert-outcome
  [actual : (& actual Outcome)]
  [code : i64]
  [input : i64]
  [output : i64]
  [label : String]) : unit
  (test.assert-i64-eq actual.code code (clone label))
  (test.assert-i64-eq actual.input input (clone label))
  (test.assert-i64-eq actual.output output label))

(define (record!
  [result : (&mut result Outcome)]
  [code : i64]
  [id : i64]
  [input : i64]
  [output : i64]
  [work : i64]) : unit
  (set! result.code code)
  (set! result.id id)
  (set! result.input input)
  (set! result.output output)
  (set! result.work work))

;; Offer [0, split) first, then `chunk` more bytes after each NeedInput. EOF is
;; set once the offered end reaches the input end. With `probe`, every third
;; call offers no output space. Output must be a prefix of `expected`.
(define (run-case-into
  [result : (&mut result Outcome)]
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [dictionary : (& dictionary bytes)]
  [supplied : bool]
  [expected : (& expected bytes)]
  [split : i64]
  [chunk : i64]
  [capacity : i64]
  [probe : bool]) : unit
  (with-arena
    run
    (match (zlib.decoder-new limits (& (zlib.AllowDictionary)))
      [(zlib.ZlibNewErr error)
        (record!
          result
          (kind-code (& error.kind))
          -1
          error.input
          error.output
          0)]
      [(zlib.ZlibNewOk state)
        (let
          [out : byte_buf.ByteBuf (repeat-byte capacity (cast 204 : u8))]
          [length : i64 (byte_buf.bytes-length input)]
          [position : i64 0]
          [end : i64 split]
          [written : i64 0]
          [calls : i64 0]
          [allocation : i64 (profile.alloc-total)]
          (while true
            (when
              (>= calls 100000)
              (test.assert-true false "bounded stream calls")
              (return (record! result -3 -1 0 0 0)))
            (let
              [offered : i64
                (if (and probe (= (% calls 3) 0))
                  0
                  capacity)]
              [step : zlib.ZlibStep
                (zlib.step!
                  (&mut state)
                  (byte_buf.bytes-slice-view input position (- end position))
                  (byte_buf.bytes-mut-slice-view
                    (byte_buf.as-mut-bytes (&mut out))
                    0
                    offered)
                  (= end length))]
              (test.assert-true
                (and (>= step.consumed 0) (<= step.consumed (- end position)))
                "consumption within offered input")
              (test.assert-true
                (and (>= step.produced 0) (<= step.produced offered))
                "production within offered output")
              (for [index (iterator.range 0 step.produced)]
                (test.assert-true
                  (< (+ written index) (byte_buf.bytes-length expected))
                  "output length bound")
                (test.assert-i64-eq
                  (cast (byte_buf.ref out index) : i64)
                  (cast
                    (byte_buf.bytes-get
                      expected
                      (+ written index)
                      (cast 0 : u8))
                    : i64)
                  "stream output byte"))
              (set! position (+ position step.consumed))
              (set! written (+ written step.produced))
              (set! calls (+ calls 1))
              (match step.status
                [(zlib.NeedInput)
                  (test.assert-true (< end length) "EOF must not need input")
                  (test.assert-i64-eq position end "offered input exhausted")
                  (set!
                    end
                    (if (> chunk (- length end))
                      length
                      (+ end chunk)))]
                [(zlib.NeedOutput)
                  (when
                    probe
                    (assert-repeat
                      (&mut state)
                      (byte_buf.bytes-slice-view input 0 0)
                      (byte_buf.bytes-mut-slice-view
                        (byte_buf.as-mut-bytes (&mut out))
                        0
                        0)
                      -5))]
                [(zlib.NeedDictionary id)
                  (assert-repeat
                    (&mut state)
                    (byte_buf.bytes-slice-view input position (- end position))
                    (byte_buf.as-mut-bytes (&mut out))
                    -2)
                  (unless
                    supplied
                    (return
                      (record!
                        result
                        -2
                        id
                        position
                        written
                        (zlib.work-total (& state)))))
                  (zlib.set-dictionary! (&mut state) dictionary)
                  unit]
                [(zlib.Error error)
                  (assert-repeat
                    (&mut state)
                    input
                    (byte_buf.as-mut-bytes (&mut out))
                    (kind-code (& error.kind)))
                  (test.assert-i64-eq
                    (profile.alloc-total)
                    allocation
                    "failed stream allocates nothing")
                  (return
                    (record!
                      result
                      (kind-code (& error.kind))
                      -1
                      error.input
                      error.output
                      (zlib.work-total (& state))))]
                [(zlib.Done)
                  (test.assert-i64-eq
                    written
                    (byte_buf.bytes-length expected)
                    "complete stream output")
                  (test.assert-i64-eq
                    (zlib.input-total (& state))
                    position
                    "member input total")
                  (test.assert-i64-eq
                    (zlib.output-total (& state))
                    written
                    "member output total")
                  (assert-repeat
                    (&mut state)
                    input
                    (byte_buf.as-mut-bytes (&mut out))
                    -1)
                  (test.assert-i64-eq
                    (profile.alloc-total)
                    allocation
                    "streaming engine allocates nothing")
                  (return
                    (record!
                      result
                      -1
                      -1
                      position
                      written
                      (zlib.work-total (& state))))])))
          (record! result -3 -1 0 0 0))])))

(define (run-case
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [dictionary : (& dictionary bytes)]
  [supplied : bool]
  [expected : (& expected bytes)]
  [split : i64]
  [chunk : i64]
  [capacity : i64]
  [probe : bool]) : Outcome
  (let
    [result : Outcome (Outcome -3 -1 0 0 0)]
    (run-case-into
      (&mut result)
      input
      limits
      dictionary
      supplied
      expected
      split
      chunk
      capacity
      probe)
    result))

;; Run `input` once whole and again at every split, then byte at a time.
;; Every outcome, including total work, must match the whole-input run.
(define (split-outcome
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [dictionary : (& dictionary bytes)]
  [supplied : bool]
  [expected : (& expected bytes)]
  [every : bool]) : Outcome
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [whole : Outcome
      (run-case
        input
        limits
        dictionary
        supplied
        expected
        length
        length
        4096
        false)]
    (for [split (iterator.range 0 (+ length 1))]
      (when
        (or every (< split 3) (> split (- length 3)))
        (assert-same
          (&
            (run-case
              input
              limits
              dictionary
              supplied
              expected
              split
              length
              (+ 1 (% split 8))
              (= (% split 2) 0)))
          (& whole)
          "split outcome")))
    (assert-same
      (& (run-case input limits dictionary supplied expected 0 1 3 true))
      (& whole)
      "byte-at-a-time outcome")
    whole))

;; Dynamic fixtures 3-5 are large; every other fixture runs every split.
(define (small-fixture? [index : i64]) : bool
  (or (< index 3) (> index 5)))

(define (assert-fixtures) : unit
  (for [index (iterator.range 0 17)]
    (with-arena
      fixture
      (let
        [input : byte_buf.ByteBuf (fixture-input index)]
        [expected : byte_buf.ByteBuf (fixture-output index)]
        [dictionary : byte_buf.ByteBuf (dictionary-bytes index)]
        [supplied : bool (> dictionary.len 0)]
        [limits : deflate.DeflateLimits (deflate.default-limits)]
        [member : i64 (- input.len 2)]
        [whole : Outcome
          (split-outcome
            (byte_buf.as-bytes (& input))
            (& limits)
            (byte_buf.as-bytes (& dictionary))
            supplied
            (byte_buf.as-bytes (& expected))
            (small-fixture? index))]
        (assert-outcome (& whole) -1 member expected.len "valid member")
        (match (if supplied
          (zlib.decode-with-dictionary
            (byte_buf.as-bytes (& input))
            (& limits)
            (byte_buf.as-bytes (& dictionary)))
          (zlib.decode
            (byte_buf.as-bytes (& input))
            (& limits)
            (& (zlib.ForbidDictionary))))
          [(zlib.ZlibDecodeErr error)
            (test.assert-i64-eq (kind-code (& error.kind)) -1 "one-shot member")]
          [(zlib.ZlibDecodeOk decoded)
            (test.assert-i64-eq decoded.consumed member "one-shot consumption")
            (test.assert-i64-eq
              (byte_buf.len decoded.bytes)
              expected.len
              "one-shot length")
            (for [offset (iterator.range 0 expected.len)]
              (test.assert-i64-eq
                (cast (byte_buf.ref decoded.bytes offset) : i64)
                (cast (byte_buf.ref expected offset) : i64)
                "one-shot byte"))])))))

;; Header failures stop after both header bytes; nothing later is read.
(define (malformed-header [index : i64]) : String
  (cond
    [(= index 0) "7709"]
    [(= index 1) "7f07"]
    [(= index 2) "881c"]
    [(= index 3) "f800"]
    [(= index 4) "789d"]
    [else "7700"]))

(define (malformed-kind [index : i64]) : i64
  (cond [(< index 2) 2] [(< index 4) 3] [else 4]))

(define (assert-malformed-headers) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [none : byte_buf.ByteBuf (byte_buf.new)]
    (for [index (iterator.range 0 6)]
      (let
        [suffix : byte_buf.ByteBuf (hex-bytes "0300000000010000a55a")]
        [input : byte_buf.ByteBuf
          (byte_buf.append-bytes
            (hex-bytes (malformed-header index))
            (byte_buf.as-bytes (& suffix)))]
        (assert-outcome
          (&
            (split-outcome
              (byte_buf.as-bytes (& input))
              (& limits)
              (byte_buf.as-bytes (& none))
              false
              (byte_buf.as-bytes (& none))
              true))
          (malformed-kind index)
          2
          0
          "malformed header")))
    (for [index (iterator.range 6 13)]
      (let
        [input : byte_buf.ByteBuf (fixture-input index)]
        [declared : i64 (shl 1 (+ (- index 5) 8))]
        [narrow : deflate.DeflateLimits (deflate.default-limits)]
        (set! narrow.window-bytes (- declared 1))
        (assert-outcome
          (&
            (split-outcome
              (byte_buf.as-bytes (& input))
              (& narrow)
              (byte_buf.as-bytes (& none))
              false
              (byte_buf.as-bytes (& none))
              true))
          18
          2
          0
          "declared window beyond history")
        (set! narrow.window-bytes declared)
        (match (zlib.decode
          (byte_buf.as-bytes (& input))
          (& narrow)
          (& (zlib.ForbidDictionary)))
          [(zlib.ZlibDecodeOk decoded)
            (test.assert-i64-eq decoded.consumed (- input.len 2) "exact window")]
          [(zlib.ZlibDecodeErr _) (test.assert-true false "exact window")])))
    (let
      [input : byte_buf.ByteBuf (fixture-input 13)]
      [narrow : deflate.DeflateLimits (deflate.default-limits)]
      (set! narrow.window-bytes 255)
      (match (zlib.decode
        (byte_buf.as-bytes (& input))
        (& narrow)
        (& (zlib.ForbidDictionary)))
        [(zlib.ZlibDecodeErr error)
          (test.assert-i64-eq (kind-code (& error.kind)) 18 "CINFO 0 window")]
        [_ (test.assert-true false "CINFO 0 window")])
      (set! narrow.window-bytes 256)
      (match (zlib.decode
        (byte_buf.as-bytes (& input))
        (& narrow)
        (& (zlib.ForbidDictionary)))
        [(zlib.ZlibDecodeOk decoded)
          (test.assert-i64-eq decoded.consumed 14 "CINFO 0 member")]
        [(zlib.ZlibDecodeErr _) (test.assert-true false "CINFO 0 member")]))))

(define (dictionary-error [result : zlib.ZlibDecodeResult]) : Outcome
  (match result
    [(zlib.ZlibDecodeOk decoded) (Outcome -1 -1 decoded.consumed 0 0)]
    [(zlib.ZlibDecodeErr error)
      (Outcome
        (kind-code (& error.kind))
        (match error.kind
          [(zlib.DictionaryRequired id) id]
          [_ -1])
        error.input
        error.output
        0)]))

(define (assert-dictionaries) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [input : byte_buf.ByteBuf (fixture-input 14)]
    [expected : byte_buf.ByteBuf (fixture-output 14)]
    [dictionary : byte_buf.ByteBuf (dictionary-bytes 14)]
    [wrong : byte_buf.ByteBuf (hex-bytes "616264")]
    [id : i64 (adler32.checksum (byte_buf.as-bytes (& dictionary)))]
    (let
      [missing : Outcome
        (dictionary-error
          (zlib.decode
            (byte_buf.as-bytes (& input))
            (& limits)
            (& (zlib.AllowDictionary))))]
      (assert-outcome (& missing) 6 6 0 "missing dictionary")
      (test.assert-i64-eq missing.id id "required dictionary identifier"))
    (assert-outcome
      (&
        (dictionary-error
          (zlib.decode
            (byte_buf.as-bytes (& input))
            (& limits)
            (& (zlib.ForbidDictionary)))))
      5
      2
      0
      "forbidden dictionary")
    (assert-outcome
      (&
        (dictionary-error
          (zlib.decode-with-dictionary
            (byte_buf.as-bytes (& input))
            (& limits)
            (byte_buf.as-bytes (& wrong)))))
      7
      6
      0
      "mismatched dictionary")
    (let
      [request : Outcome
        (split-outcome
          (byte_buf.as-bytes (& input))
          (& limits)
          (byte_buf.as-bytes (& wrong))
          false
          (byte_buf.as-bytes (& expected))
          true)]
      (assert-outcome (& request) -2 6 0 "incremental dictionary request")
      (test.assert-i64-eq request.id id "incremental identifier"))
    (assert-outcome
      (&
        (split-outcome
          (byte_buf.as-bytes (& input))
          (& limits)
          (byte_buf.as-bytes (& wrong))
          true
          (byte_buf.as-bytes (& expected))
          true))
      7
      6
      0
      "incremental mismatch is sticky")
    (let
      [plain : byte_buf.ByteBuf (fixture-input 1)]
      (match (zlib.decode-with-dictionary
        (byte_buf.as-bytes (& plain))
        (& limits)
        (byte_buf.as-bytes (& wrong)))
        [(zlib.ZlibDecodeOk decoded)
          (test.assert-i64-eq decoded.consumed 16 "unnamed dictionary unused")]
        [(zlib.ZlibDecodeErr _)
          (test.assert-true false "unnamed dictionary unused")]))
    (let
      [beyond : byte_buf.ByteBuf (hex-bytes "7820024d012703620000000000a55a")]
      [abc : byte_buf.ByteBuf (hex-bytes "616263")]
      [none : byte_buf.ByteBuf (byte_buf.new)]
      (assert-outcome
        (&
          (split-outcome
            (byte_buf.as-bytes (& beyond))
            (& limits)
            (byte_buf.as-bytes (& abc))
            true
            (byte_buf.as-bytes (& none))
            true))
        14
        8
        0
        "reference before the dictionary"))
    (let
      [narrow : deflate.DeflateLimits (deflate.default-limits)]
      (set! narrow.max-work (+ 33495 (- dictionary.len 1)))
      (assert-outcome
        (&
          (split-outcome
            (byte_buf.as-bytes (& input))
            (& narrow)
            (byte_buf.as-bytes (& dictionary))
            true
            (byte_buf.as-bytes (& expected))
            true))
        19
        6
        0
        "dictionary bytes are charged"))
    (match (zlib.decoder-new (& limits) (& (zlib.AllowDictionary)))
      [(zlib.ZlibNewErr _) (test.assert-true false "dictionary phase setup")]
      [(zlib.ZlibNewOk state)
        (let
          [out : byte_buf.ByteBuf (repeat-byte 64 (cast 0 : u8))]
          (match (zlib.set-dictionary!
            (&mut state)
            (byte_buf.as-bytes (& dictionary)))
            [(zlib.DictionaryRejected error)
              (test.assert-i64-eq
                (kind-code (& error.kind))
                1
                "early dictionary")]
            [(zlib.DictionaryAccepted)
              (test.assert-true false "early dictionary")])
          (test.assert-i64-eq state.phase 0 "early dictionary changes nothing")
          (let
            [plain : byte_buf.ByteBuf (fixture-input 1)]
            [result : zlib.ZlibStep
              (zlib.step!
                (&mut state)
                (byte_buf.as-bytes (& plain))
                (byte_buf.as-mut-bytes (&mut out))
                true)]
            (test.assert-i64-eq
              (status-code (& result.status))
              -1
              "still decodes"))
          (match (zlib.set-dictionary!
            (&mut state)
            (byte_buf.as-bytes (& dictionary)))
            [(zlib.DictionaryRejected error)
              (test.assert-i64-eq
                (kind-code (& error.kind))
                1
                "late dictionary")]
            [(zlib.DictionaryAccepted)
              (test.assert-true false "late dictionary")])
          (test.assert-i64-eq state.phase 5 "Done survives a late dictionary"))])))

;; Every prefix of a member is Truncated at its own length, never Done.
(define (assert-truncation) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (for [index (iterator.range 0 17)]
      (when
        (small-fixture? index)
        (with-arena
          truncated
          (let
            [member : byte_buf.ByteBuf (member-bytes index)]
            [expected : byte_buf.ByteBuf (fixture-output index)]
            [dictionary : byte_buf.ByteBuf (dictionary-bytes index)]
            (for [length (iterator.range 0 member.len)]
              (let
                [prefix : byte_buf.ByteBuf
                  (byte_buf.from-bytes-range
                    (byte_buf.as-bytes (& member))
                    0
                    length)]
                [outcome : Outcome
                  (run-case
                    (byte_buf.as-bytes (& prefix))
                    (& limits)
                    (byte_buf.as-bytes (& dictionary))
                    true
                    (byte_buf.as-bytes (& expected))
                    (/ length 2)
                    length
                    5
                    true)]
                (test.assert-i64-eq outcome.code 12 "truncated member")
                (test.assert-i64-eq outcome.input length "truncated position")
                (test.assert-true
                  (<= outcome.output expected.len)
                  "truncated output is a prefix")))))))))

(define (fixture-outcome
  [index : i64]
  [limits : (& limits deflate.DeflateLimits)]) : Outcome
  (let
    [input : byte_buf.ByteBuf (fixture-input index)]
    [expected : byte_buf.ByteBuf (fixture-output index)]
    [dictionary : byte_buf.ByteBuf (dictionary-bytes index)]
    (split-outcome
      (byte_buf.as-bytes (& input))
      limits
      (byte_buf.as-bytes (& dictionary))
      true
      (byte_buf.as-bytes (& expected))
      (small-fixture? index))))

(define (flipped [member : (& member bytes)] [position : i64]) : byte_buf.ByteBuf
  (let
    [suffix : byte_buf.ByteBuf (hex-bytes "a55a")]
    [input : byte_buf.ByteBuf
      (byte_buf.append-bytes
        (byte_buf.from-bytes member)
        (byte_buf.as-bytes (& suffix)))]
    [value : i64 (bit-xor (cast (byte_buf.ref input position) : i64) 1)]
    (byte_buf.set! input position (cast value : u8))))

;; A wrong trailer reports ChecksumMismatch after the whole member and its
;; complete tentative output; it is never Done.
(define (assert-checksums) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (for [index (iterator.range 0 17)]
      (with-arena
        checksum
        (let
          [member : byte_buf.ByteBuf (member-bytes index)]
          [expected : byte_buf.ByteBuf (fixture-output index)]
          [dictionary : byte_buf.ByteBuf (dictionary-bytes index)]
          (for [offset (iterator.range 0 4)]
            (let
              [input : byte_buf.ByteBuf
                (flipped
                  (byte_buf.as-bytes (& member))
                  (+ (- member.len 4) offset))]
              (assert-outcome
                (&
                  (split-outcome
                    (byte_buf.as-bytes (& input))
                    (& limits)
                    (byte_buf.as-bytes (& dictionary))
                    true
                    (byte_buf.as-bytes (& expected))
                    (small-fixture? index)))
                8
                member.len
                expected.len
                "wrong checksum"))))))
    (let
      [member : byte_buf.ByteBuf (member-bytes 1)]
      [input : byte_buf.ByteBuf (flipped (byte_buf.as-bytes (& member)) 7)]
      [expected : byte_buf.ByteBuf (hex-bytes "69656c6c6f")]
      [none : byte_buf.ByteBuf (byte_buf.new)]
      (assert-outcome
        (&
          (split-outcome
            (byte_buf.as-bytes (& input))
            (& limits)
            (byte_buf.as-bytes (& none))
            false
            (byte_buf.as-bytes (& expected))
            true))
        8
        16
        5
        "corrupt stored payload")
      (match (zlib.decode
        (byte_buf.as-bytes (& input))
        (& limits)
        (& (zlib.ForbidDictionary)))
        [(zlib.ZlibDecodeErr error)
          (test.assert-i64-eq (kind-code (& error.kind)) 8 "one-shot checksum")]
        [(zlib.ZlibDecodeOk _) (test.assert-true false "one-shot checksum")]))))

(define (assert-adjacent-members) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [first : byte_buf.ByteBuf (member-bytes 1)]
    [second-member : byte_buf.ByteBuf (member-bytes 2)]
    [both : byte_buf.ByteBuf
      (byte_buf.append-bytes
        (byte_buf.from-bytes (byte_buf.as-bytes (& first)))
        (byte_buf.as-bytes (& second-member)))]
    [expected : byte_buf.ByteBuf (fixture-output 1)]
    [none : byte_buf.ByteBuf (byte_buf.new)]
    (assert-outcome
      (&
        (split-outcome
          (byte_buf.as-bytes (& both))
          (& limits)
          (byte_buf.as-bytes (& none))
          false
          (byte_buf.as-bytes (& expected))
          true))
      -1
      16
      5
      "first member stops at its trailer")
    (match (zlib.decode
      (byte_buf.as-bytes (& both))
      (& limits)
      (& (zlib.ForbidDictionary)))
      [(zlib.ZlibDecodeErr _) (test.assert-true false "first adjacent member")]
      [(zlib.ZlibDecodeOk decoded)
        (test.assert-i64-eq decoded.consumed 16 "first member length")
        (match (zlib.decode
          (byte_buf.bytes-slice-view
            (byte_buf.as-bytes (& both))
            decoded.consumed
            (- both.len decoded.consumed))
          (& limits)
          (& (zlib.ForbidDictionary)))
          [(zlib.ZlibDecodeErr _)
            (test.assert-true false "second adjacent member")]
          [(zlib.ZlibDecodeOk second)
            (test.assert-i64-eq second.consumed 20 "second member length")
            (test.assert-i64-eq
              (byte_buf.len second.bytes)
              22
              "second member output")])])))

(define (limits-with [field : i64] [value : i64]) : deflate.DeflateLimits
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (cond
      [(= field 0) (set! limits.max-input value)]
      [(= field 1) (set! limits.max-output value)]
      [else (set! limits.max-work value)])
    limits))

;; Every limit counts the whole member, including its framing bytes, and the
;; same decision is reached at every split.
(define (assert-limits) : unit
  (let
    [base : Outcome (fixture-outcome 2 (& (deflate.default-limits)))]
    [work : i64 base.work]
    (assert-outcome (& base) -1 20 22 "limit baseline")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 0 20))))
      -1
      20
      22
      "exact member input")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 0 19))))
      16
      19
      22
      "trailer byte counts as input")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 0 0))))
      16
      0
      0
      "first header byte counts as input")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 0 1))))
      16
      1
      0
      "second header byte counts as input")
    (assert-outcome
      (& (fixture-outcome 14 (& (limits-with 0 5))))
      16
      5
      0
      "dictionary identifier counts as input")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 1 22))))
      -1
      20
      22
      "exact output")
    (let
      [short : Outcome (fixture-outcome 2 (& (limits-with 1 21)))]
      (test.assert-i64-eq short.code 17 "output limit")
      (test.assert-i64-eq short.output 21 "output limit position"))
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 2 work))))
      -1
      20
      22
      "exact member work")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 2 (- work 1)))))
      19
      19
      22
      "trailer byte is charged")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 2 33489))))
      19
      0
      0
      "first header byte is charged")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 2 33490))))
      19
      1
      0
      "second header byte is charged")
    (assert-outcome
      (& (fixture-outcome 2 (& (limits-with 2 100))))
      19
      0
      0
      "construction work")
    (assert-outcome
      (& (fixture-outcome 2 (& (deflate.DeflateLimits 1 1 32769 1 1 1))))
      0
      0
      0
      "invalid limits")
    ;; Fixture 16 emits one literal after member byte 4 and 258 match bytes
    ;; after byte 5. Ratio 52 passes only because the two header bytes earn
    ;; credit; body bytes alone would need ratio 87.
    (assert-outcome
      (&
        (fixture-outcome
          16
          (& (deflate.DeflateLimits 67108864 268435456 32768 2147483647 52 0))))
      -1
      10
      259
      "header bytes earn ratio credit")
    (assert-outcome
      (&
        (fixture-outcome
          16
          (& (deflate.DeflateLimits 67108864 268435456 32768 2147483647 51 0))))
      20
      5
      255
      "ratio limit")
    (assert-outcome
      (&
        (fixture-outcome
          16
          (& (deflate.DeflateLimits 67108864 268435456 32768 2147483647 0 259))))
      -1
      10
      259
      "startup allowance")
    (assert-outcome
      (&
        (fixture-outcome
          16
          (& (deflate.DeflateLimits 67108864 268435456 32768 2147483647 0 258))))
      20
      5
      258
      "ratio zero")))

(define (assert-forged-state) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [input : byte_buf.ByteBuf (fixture-input 0)]
    [none : byte_buf.ByteBuf (byte_buf.new)]
    (for [case (iterator.range 0 7)]
      (match (zlib.decoder-new (& limits) (& (zlib.AllowDictionary)))
        [(zlib.ZlibNewErr _) (test.assert-true false "forged state setup")]
        [(zlib.ZlibNewOk state)
          (cond
            [(= case 0) (set! state.phase 7)]
            [(= case 1) (set! state.field-read 2)]
            [(= case 2) (set! state.framing 1)]
            [(= case 3) (set! state.checksum 65521)]
            [(= case 4) (set! state.dictionary-id -2)]
            [(= case 5) (set! state.field 1)]
            [else (set! state.raw.work -1)])
          (let
            [out : byte_buf.ByteBuf (repeat-byte 4 (cast 0 : u8))]
            (match (zlib.set-dictionary!
              (&mut state)
              (byte_buf.as-bytes (& none)))
              [(zlib.DictionaryRejected error)
                (test.assert-i64-eq
                  (kind-code (& error.kind))
                  1
                  "forged dictionary")]
              [(zlib.DictionaryAccepted)
                (test.assert-true false "forged dictionary")])
            (let
              [result : zlib.ZlibStep
                (zlib.step!
                  (&mut state)
                  (byte_buf.as-bytes (& input))
                  (byte_buf.as-mut-bytes (&mut out))
                  true)]
              (test.assert-i64-eq
                result.consumed
                0
                "forged state consumes nothing")
              (test.assert-i64-eq
                result.produced
                0
                "forged state emits nothing")
              (test.assert-i64-eq
                (status-code (& result.status))
                1
                "forged state is rejected")))]))))

(define (assert-arenas) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (match (zlib.decoder-new (& limits) (& (zlib.ForbidDictionary)))
      [(zlib.ZlibNewErr _) (test.assert-true false "scoped chunks setup")]
      [(zlib.ZlibNewOk state)
        (with-arena
          first-chunk
          (let
            [input : byte_buf.ByteBuf (hex-bytes "7801cb48cd")]
            [out : byte_buf.ByteBuf (repeat-byte 8 (cast 0 : u8))]
            [result : zlib.ZlibStep
              (zlib.step!
                (&mut state)
                (byte_buf.as-bytes (& input))
                (byte_buf.as-mut-bytes (&mut out))
                false)]
            (test.assert-i64-eq result.consumed 5 "first scoped chunk")
            (test.assert-i64-eq
              (status-code (& result.status))
              -4
              "needs input")))
        (with-arena
          second-chunk
          (let
            [input : byte_buf.ByteBuf
              (hex-bytes "c9c957c84022ab723293005f9f084e")]
            [out : byte_buf.ByteBuf (repeat-byte 64 (cast 0 : u8))]
            [result : zlib.ZlibStep
              (zlib.step!
                (&mut state)
                (byte_buf.as-bytes (& input))
                (byte_buf.as-mut-bytes (&mut out))
                true)]
            (test.assert-i64-eq result.consumed 15 "second scoped chunk")
            (test.assert-i64-eq (status-code (& result.status)) -1 "completes")))
        (test.assert-i64-eq (zlib.output-total (& state)) 22 "scoped output")])
    (let
      [before : i64 (profile.alloc-live)]
      (for [index (iterator.range 0 64)]
        (with-arena
          cancelled
          (match (zlib.decoder-new (& limits) (& (zlib.AllowDictionary)))
            [(zlib.ZlibNewErr _) (test.assert-true false "cancelled setup")]
            [(zlib.ZlibNewOk state)
              (let
                [input : byte_buf.ByteBuf (hex-bytes "78f9613c")]
                [out : byte_buf.ByteBuf (repeat-byte 0 (cast 0 : u8))]
                [result : zlib.ZlibStep
                  (zlib.step!
                    (&mut state)
                    (byte_buf.as-bytes (& input))
                    (byte_buf.as-mut-bytes (&mut out))
                    false)]
                (test.assert-i64-eq
                  (status-code (& result.status))
                  -4
                  "cancel inside the identifier"))])))
      (test.assert-i64-eq
        (profile.alloc-live)
        before
        "partial decoder arenas fully released"))
    (let
      [raw-before : i64 (profile.alloc-total)]
      (match (deflate.decoder-new (& limits))
        [(deflate.DeflateNewErr _)
          (test.assert-true false "raw allocation setup")]
        [(deflate.DeflateNewOk _) unit])
      (let
        [raw : i64 (- (profile.alloc-total) raw-before)]
        [before : i64 (profile.alloc-total)]
        (match (zlib.decoder-new (& limits) (& (zlib.ForbidDictionary)))
          [(zlib.ZlibNewErr _) (test.assert-true false "allocation setup")]
          [(zlib.ZlibNewOk _) unit])
        (test.assert-true (> raw 0) "allocation counter is active")
        (test.assert-i64-eq
          (- (profile.alloc-total) before)
          raw
          "zlib adds no allocation to the raw decoder")))))

(define (assert-adler [text : String] [expected : i64]) : unit
  (let
    [view (byte_buf.str-as-bytes (& text))]
    [length : i64 (byte_buf.bytes-length view)]
    (test.assert-i64-eq (adler32.checksum view) expected "Adler-32 vector")
    (for [split (iterator.range 0 (+ length 1))]
      (test.assert-i64-eq
        (adler32.update
          (adler32.update
            (adler32.initial)
            (byte_buf.bytes-slice-view view 0 split))
          (byte_buf.bytes-slice-view view split (- length split)))
        expected
        "Adler-32 split"))))

(define (assert-adler32) : unit
  (assert-adler "" 1)
  (assert-adler "a" 6422626)
  (assert-adler "abc" 38600999)
  (assert-adler "message digest" 695534982)
  (assert-adler "abcdefghijklmnopqrstuvwxyz" 2424703776)
  (assert-adler
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    2329613580)
  (assert-adler
    "12345678901234567890123456789012345678901234567890123456789012345678901234567890"
    2545291369)
  (assert-adler "Wikipedia" 300286872)
  (let
    [ones : byte_buf.ByteBuf (repeat-byte 1048576 (cast 255 : u8))]
    [view (byte_buf.as-bytes (& ones))]
    [position : i64 0]
    [running : i64 (adler32.initial)]
    [step : i64 0]
    (test.assert-i64-eq (adler32.checksum view) 2391338769 "1 MiB of 0xff")
    (while (< position ones.len)
      (let
        [size : i64
          (cond
            [(= (% step 4) 0) 5551]
            [(= (% step 4) 1) 5553]
            [(= (% step 4) 2) 1]
            [else 65536])]
        [count : i64
          (if (< size (- ones.len position))
            size
            (- ones.len position))]
        (set!
          running
          (adler32.update
            running
            (byte_buf.bytes-slice-view view position count)))
        (set! position (+ position count))
        (set! step (+ step 1))))
    (test.assert-i64-eq running 2391338769 "uneven 1 MiB chunks"))
  (let
    [empty : byte_buf.ByteBuf (byte_buf.new)]
    (test.assert-i64-eq
      (adler32.update -1 (byte_buf.as-bytes (& empty)))
      917518
      "out-of-range checksum halves are reduced")))

(test zlib-valid-members-every-split (assert-fixtures))

(test zlib-malformed-header-and-window (assert-malformed-headers))

(test zlib-preset-dictionaries (assert-dictionaries))

(test zlib-truncated-members (assert-truncation))

(test zlib-wrong-checksum-never-done (assert-checksums))

(test zlib-adjacent-members (assert-adjacent-members))

(test zlib-limits-count-framing (assert-limits))

(test zlib-forged-state (assert-forged-state))

(test zlib-arena-lifetimes (assert-arenas))

(test adler32-vectors-and-splits (assert-adler32))

(define (main) : i64
  (assert-adler32)
  (assert-fixtures)
  (assert-malformed-headers)
  (assert-dictionaries)
  (assert-truncation)
  (assert-checksums)
  (assert-adjacent-members)
  (assert-limits)
  (assert-forged-state)
  (assert-arenas)
  42)