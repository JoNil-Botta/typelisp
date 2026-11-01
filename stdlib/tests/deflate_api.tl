(import stdlib.compress.deflate)
(import stdlib.byte_buf)
(import stdlib.test)
(import stdlib.iterator)
(import stdlib.profile)

(define (new-decoder) : deflate.DeflateNewResult
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (deflate.decoder-new (& limits))))

(define (decode-default [input : (& input bytes)]) : deflate.DeflateDecodeResult
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (deflate.decode input (& limits))))

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

(define (assert-decode [hex : String] [expected : String] [consumed : i64]) : unit
  (let
    [input : byte_buf.ByteBuf (hex-bytes hex)]
    (match (decode-default (byte_buf.as-bytes (& input)))
      [(deflate.DeflateDecodeErr error)
        (test.assert-i64-eq error.input -1 "unexpected decoder error")]
      [(deflate.DeflateDecodeOk decoded)
        (let
          [actual : String (byte_buf.to-string decoded.bytes)]
          (test.assert-string-eq (& actual) (& expected) "decoded output")
          (test.assert-i64-eq decoded.consumed consumed "exact member length"))])))

(define (fixture-input [index : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push
      (hex-bytes
        (cond
          [(= index 0) "0300"]
          [(= index 1) "03fc"]
          [(= index 2) "010000ffff"]
          [(= index 3) "f90500faff68656c6c6f"]
          [(= index 4) "731c0500"]
          [(= index 5) "4a4c020c0c01"]
          [(= index 6) "05c0810800000000207febf3"]
          [(= index 7) "05c081080000000020b6fda50e01"]
          [(= index 8) "0500370900302c7b27f52ff62870ef03"]
          [(= index 9) "05df04090020bbbbfbff4cbbbb5b21c21f"]
          [(= index 10) "bb0400"]
          [(= index 11) "0b5acfe60b00"]
          [(= index 12) "13ff937e657eda6300"]
          [(= index 13) "db977357564b4ff04b813300"]
          [(= index 14) "5bd23373f78ac87b930e6efc79e42b00"]
          [(= index 15) "9be820ff9ff9efd6b3f7772f965bd2c1cd0800"]
          [(= index 16) "7b9fe5c719ef3e3326748769847c63d88dd6c9fe00"]
          [(= index 17) "639e19e369ffcfa720f6fc73e116de86ef5dcc37aefa270200"]
          [(= index 18)
            "35514bb685200c5b6bd2825f2a2a5ed1d5bf38783069396992866c70dd7d2b79e1e080139cefea6c9b813003ea88a2726e8e69c78f3519ec4480c25608012bbff83a7c67d3501795f5057c0ff5824604ba8d4f49580ced188008faee9825daeb61d7d9b0a4345e5c016e07718b7b9d6e3c69eb8f062ebb5624acbecd2dea2e390ff7e3636046868dcccebd50e20c398b6f37a3db5b819966596626709555337326170907fbe6796320e2f5e4af98cb0519deaabbb9478d68090f206cac94826562049fc42267dfdac97ef8cf40e92817690df8593f57acdfe3ec1bb2aab188e65488a742ebe6b27606de89ad65b63e4b9ed66c77d9138d6447981b0efd8d783b9482ce19cebb35a192b373e27c6ca8567053cda81eafa6f02549bf1671a56bc20b9f0c0b3015fb03"]
          [(= index 20) "0dc1010900000080a06df57f54212e"]
          [else
            "731c05a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a468123f0fe7f00"]))
      (cast 165 : u8))
    (cast 90 : u8)))

(define (repeat-byte [count : i64] [byte : u8]) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    (for [index (iterator.range 0 count)]
      (set! (array-ref slots index) byte))
    (byte_buf.from-array slots)))

(define (fixture-output [index : i64]) : byte_buf.ByteBuf
  (cond
    [(= index 0) (hex-bytes "")]
    [(= index 1) (hex-bytes "")]
    [(= index 2) (hex-bytes "")]
    [(= index 3) (hex-bytes "68656c6c6f")]
    [(= index 4)
      (hex-bytes
        "41414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141")]
    [(= index 5) (hex-bytes "61626162616261")]
    [(= index 6) (hex-bytes "")]
    [(= index 7) (hex-bytes "414141")]
    [(= index 8) (hex-bytes "000e0f")]
    [(= index 9) (hex-bytes "010203")]
    [(= index 10) (hex-bytes "d2")]
    [(= index 11) (hex-bytes "52af064d")]
    [(= index 12) (hex-bytes "17fc67d49f66e3")]
    [(= index 13) (hex-bytes "be6cdd1d2a2e11f47043")]
    [(= index 14) (hex-bytes "a48c99bba859de92c1b1f9c4f5")]
    [(= index 15) (hex-bytes "91401fff03fdb5cddfbba31ea4880b01")]
    [(= index 16) (hex-bytes "ef6a4e095f47995c55b835581f8156d885934f")]
    [(= index 17) (hex-bytes "03995c493ffe4c705dcfe713840d80f78a03d8d54f61")]
    [(= index 18)
      (hex-bytes
        "66636164616461716f6d666b6267646161646261626a77706462746f63616261636361617068616d6162616a7464616971617662706563616373616e6162626162706163616161636d766e6262616261616161616f6363617864616163786b61627a72616f636e61626e6e6e61786368796d65616b636174726761616e6e62647164616a61616478707263757374616b65656875626c6161626f726261776163616c69776179656f78796761617563756c6165616c646f6a746e7071616261646e646472616a61616266616661636862666462716d62646161626e7061636e64616461636264637a7061616a62636366616f636961626c62616263636364626564616261626763616266616277616762616e7a6465647a6261646d75616178636f7064646364646e706e6e7465617961616763616e6c62626461636662616861627965626d6161756161616f656376616261626161616161616e616361616369616761766378736c616c616161616a646f61666c6161686d67636173616373736262617863646a6263736e617a69627474666274786a6261646263746371646461626361617961616861636463617261626a6163617861616561616161736e6462777474646461656462786269626a726f6170636d6177626269626869626a617a64636161626177616264756b626361657569617a61646963616b6161696d63")]
    [(= index 20) (hex-bytes "4142414241")]
    [else (repeat-byte 32771 (cast 65 : u8))]))

;; Fixtures 18 and 19 are large boundary streams; every other fixture runs
;; every input split.
(define (small-fixture? [index : i64]) : bool
  (or (< index 18) (> index 19)))

(define (kind-code [kind : (& kind deflate.DeflateErrorKind)]) : i64
  (match kind
    [(deflate.InvalidLimits) 0]
    [(deflate.InvalidState) 1]
    [(deflate.MalformedBlock) 2]
    [(deflate.MalformedTree) 3]
    [(deflate.InvalidCode) 4]
    [(deflate.Truncated) 5]
    [(deflate.ReservedEncoding) 6]
    [(deflate.InvalidDistance) 7]
    [(deflate.Overflow) 8]
    [(deflate.InputLimit) 9]
    [(deflate.OutputLimit) 10]
    [(deflate.WindowLimit) 11]
    [(deflate.WorkLimit) 12]
    [(deflate.RatioLimit) 13]))

(define (assert-repeat-output
  [state : (&mut state deflate.Decoder)]
  [empty : (& empty bytes)]
  [output : (&mut output bytes)]) : unit
  (let
    [work : i64 state.work]
    [probe : deflate.DeflateStep (deflate.step! state empty output false)]
    (test.assert-i64-eq probe.consumed 0 "blocked output consumes nothing")
    (test.assert-i64-eq probe.produced 0 "blocked output emits nothing")
    (test.assert-i64-eq state.work work "blocked output does not charge")
    (match probe.status
      [(deflate.NeedOutput) unit]
      [_ (test.assert-true false "repeated zero output stays blocked")])))

(define (stream-case
  [input : (& input bytes)]
  [expected : (& expected bytes)]
  [split : i64]
  [capacity : i64]
  [probe : bool]
  [member-length : i64]) : i64
  (with-arena
    stream
    (match (new-decoder)
      [(deflate.DeflateNewErr _)
        (test.assert-true false "stream construction")
        0]
      [(deflate.DeflateNewOk state)
        (let
          [out : byte_buf.ByteBuf (repeat-byte capacity (cast 204 : u8))]
          [position : i64 0]
          [written : i64 0]
          [front : bool true]
          [calls : i64 0]
          [allocation : i64 (profile.alloc-total)]
          (when
            probe
            (let
              [initial : i64 state.work]
              [empty-result : deflate.DeflateStep
                (deflate.step!
                  (&mut state)
                  (byte_buf.bytes-slice-view input 0 0)
                  (byte_buf.bytes-mut-slice-view
                    (byte_buf.as-mut-bytes (&mut out))
                    0
                    0)
                  false)]
              (test.assert-i64-eq
                empty-result.consumed
                0
                "empty initial consumption")
              (test.assert-i64-eq
                empty-result.produced
                0
                "empty initial output")
              (test.assert-i64-eq state.work initial "empty initial work")
              (match empty-result.status
                [(deflate.NeedInput) unit]
                [_ (test.assert-true false "empty initial needs input")])))
          (while true
            (when
              (>= calls 200000)
              (test.assert-true false "bounded stream calls")
              (return 0))
            (let
              [end : i64
                (if front
                  split
                  (byte_buf.bytes-length input))]
              [offered : i64
                (if (and probe (= (% calls 3) 0))
                  0
                  capacity)]
              [result : deflate.DeflateStep
                (deflate.step!
                  (&mut state)
                  (byte_buf.bytes-slice-view input position (- end position))
                  (byte_buf.bytes-mut-slice-view
                    (byte_buf.as-mut-bytes (&mut out))
                    0
                    offered)
                  (not front))]
              (test.assert-true
                (and
                  (>= result.consumed 0)
                  (<= result.consumed (- end position)))
                "consumption within offered input")
              (test.assert-true
                (and (>= result.produced 0) (<= result.produced offered))
                "production within offered output")
              (for [index (iterator.range 0 result.produced)]
                (test.assert-true
                  (< (+ written index) (byte_buf.bytes-length expected))
                  "output length bound")
                (test.assert-i64-eq
                  (cast (byte_buf.ref out index) : i64)
                  (cast (byte_buf.bytes-ref expected (+ written index)) : i64)
                  "stream output byte"))
              (set! position (+ position result.consumed))
              (set! written (+ written result.produced))
              (set! calls (+ calls 1))
              (match result.status
                [(deflate.NeedInput)
                  (test.assert-true front "EOF must not need input")
                  (test.assert-i64-eq position split "input exhausted at split")
                  (set! front false)]
                [(deflate.NeedOutput)
                  (when
                    probe
                    (assert-repeat-output
                      (&mut state)
                      (byte_buf.bytes-slice-view input 0 0)
                      (byte_buf.bytes-mut-slice-view
                        (byte_buf.as-mut-bytes (&mut out))
                        0
                        0)))]
                [(deflate.Error error)
                  (test.assert-i64-eq
                    (kind-code (& error.kind))
                    -1
                    "unexpected stream error")
                  (return 0)]
                [(deflate.Done)
                  (test.assert-i64-eq
                    written
                    (byte_buf.bytes-length expected)
                    "complete stream output")
                  (test.assert-i64-eq
                    position
                    member-length
                    "trailing bytes preserved")
                  (let
                    [before : i64 state.work]
                    [again : deflate.DeflateStep
                      (deflate.step!
                        (&mut state)
                        input
                        (byte_buf.as-mut-bytes (&mut out))
                        true)]
                    (test.assert-i64-eq
                      again.consumed
                      0
                      "terminal consumes nothing")
                    (test.assert-i64-eq
                      again.produced
                      0
                      "terminal emits nothing")
                    (test.assert-i64-eq
                      state.work
                      before
                      "terminal work stable")
                    (match again.status
                      [(deflate.Done) unit]
                      [_ (test.assert-true false "terminal Done stable")]))
                  (test.assert-i64-eq
                    (profile.alloc-total)
                    allocation
                    "streaming engine allocates nothing")
                  (return state.work)])))
          0)])))

(define (assert-corpus) : unit
  (for [fixture (iterator.range 0 21)]
    (with-arena
      corpus
      (let
        [input : byte_buf.ByteBuf (fixture-input fixture)]
        [expected : byte_buf.ByteBuf (fixture-output fixture)]
        [member : i64 (- input.len 2)]
        (match (decode-default (byte_buf.as-bytes (& input)))
          [(deflate.DeflateDecodeErr error)
            (test.assert-i64-eq
              (kind-code (& error.kind))
              -1
              "corpus one-shot error")]
          [(deflate.DeflateDecodeOk decoded)
            (test.assert-i64-eq
              decoded.consumed
              member
              "one-shot member length")
            (test.assert-i64-eq
              decoded.bytes.len
              expected.len
              "one-shot output length")
            (for [index (iterator.range 0 expected.len)]
              (test.assert-i64-eq
                (cast (byte_buf.ref decoded.bytes index) : i64)
                (cast (byte_buf.ref expected index) : i64)
                "one-shot output byte"))])
        (let
          [work : i64
            (stream-case
              (byte_buf.as-bytes (& input))
              (byte_buf.as-bytes (& expected))
              input.len
              4096
              false
              member)]
          (if (small-fixture? fixture)
            (for [split (iterator.range 0 (+ input.len 1))]
              (for [capacity (iterator.range 1 9)]
                (test.assert-i64-eq
                  (stream-case
                    (byte_buf.as-bytes (& input))
                    (byte_buf.as-bytes (& expected))
                    split
                    capacity
                    true
                    member)
                  work
                  "chunk-independent work")))
            (for [choice (iterator.range 0 4)]
              (let
                [split : i64
                  (cond
                    [(= choice 0) 0]
                    [(= choice 1) 1]
                    [(= choice 2) (- member 1)]
                    [else input.len])]
                (test.assert-i64-eq
                  (stream-case
                    (byte_buf.as-bytes (& input))
                    (byte_buf.as-bytes (& expected))
                    split
                    7
                    true
                    member)
                  work
                  "boundary fixture chunk-independent work")))))))))

(define (malformed-input [index : i64]) : byte_buf.ByteBuf
  (hex-bytes
    (cond
      [(= index 0) "07"]
      [(= index 1) "010100ffff41"]
      [(= index 2) "1b03"]
      [(= index 3) "1b07"]
      [(= index 4) "73043e"]
      [(= index 5) "73047e"]
      [(= index 6) "030200"]
      [(= index 7) "f5"]
      [(= index 8) "fd"]
      [(= index 9) "05009200"]
      [(= index 10) "05000200"]
      [(= index 11) "05000224"]
      [(= index 12) "050080e4ff1f"]
      [(= index 13) "050080e47f1b"]
      [(= index 14) "05c0810800000000207feb0b0000"]
      [(= index 15) "05c0010900000080a06dfe3f1502"]
      [(= index 16) "05c0010500000000a06df57f540000"]
      [(= index 17) "0dc2010100000080906dfe9f2a0000"]
      [(= index 18) "0dc0010100000080906dfe9faa04"]
      [(= index 19) "0dc1010100000080906dfe9f2a09"]
      [(= index 22) "050000240000"]
      [(= index 20)
        "05200444fdffffffffffffffffffffffffffffffffffffffff0f8282828282828282"]
      [else "0dc1010900000080a06df57f54211e0000"])))

(define (malformed-kind [index : i64]) : i64
  (cond
    [(= index 0) 6]
    [(= index 1) 2]
    [(= index 2) 6]
    [(= index 3) 6]
    [(= index 4) 6]
    [(= index 5) 6]
    [(= index 6) 7]
    [(= index 7) 6]
    [(= index 8) 6]
    [(= index 9) 3]
    [(= index 10) 3]
    [(= index 11) 3]
    [(= index 12) 3]
    [(= index 13) 3]
    [(= index 14) 4]
    [(= index 21) 4]
    [else 3]))

;; One-shot error input position for fixtures whose failure point is pinned:
;; literal/distance tree failures stop at the end of the code-length sequence,
;; and an unused singleton code stops before the following container bytes.
;; -1 leaves the position to the chunk-split consistency checks.
(define (malformed-position [index : i64]) : i64
  (cond
    [(= index 22) 4]
    [(= index 14) 12]
    [(= index 15) 13]
    [(= index 20) 26]
    [(= index 21) 15]
    [(> index 15) 14]
    [else -1]))

(define (error-stream
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [split : i64]
  [expected : i64]) : i64
  (with-arena
    error-case
    (match (deflate.decoder-new limits)
      [(deflate.DeflateNewErr error)
        (test.assert-i64-eq
          (kind-code (& error.kind))
          expected
          "constructor error kind")
        0]
      [(deflate.DeflateNewOk state)
        (let
          [out : byte_buf.ByteBuf (repeat-byte 3 (cast 204 : u8))]
          [position : i64 0]
          [written : i64 0]
          [front : bool true]
          [calls : i64 0]
          [allocation : i64 (profile.alloc-total)]
          (while true
            (when
              (>= calls 200000)
              (test.assert-true false "bounded error stream calls")
              (return 0))
            (let
              [end : i64
                (if front
                  split
                  (byte_buf.bytes-length input))]
              [result : deflate.DeflateStep
                (deflate.step!
                  (&mut state)
                  (byte_buf.bytes-slice-view input position (- end position))
                  (byte_buf.as-mut-bytes (&mut out))
                  (not front))]
              (set! calls (+ calls 1))
              (test.assert-true
                (and
                  (>= result.consumed 0)
                  (<= result.consumed (- end position)))
                "error consumption bounded")
              (test.assert-true
                (and (>= result.produced 0) (<= result.produced 3))
                "error production bounded")
              (set! position (+ position result.consumed))
              (set! written (+ written result.produced))
              (match result.status
                [(deflate.Done)
                  (test.assert-true false "malformed/limited stream completed")
                  (return 0)]
                [(deflate.NeedInput)
                  (test.assert-true front "error EOF cannot need input")
                  (set! front false)]
                [(deflate.NeedOutput) unit]
                [(deflate.Error error)
                  (test.assert-i64-eq
                    (kind-code (& error.kind))
                    expected
                    "error kind")
                  (test.assert-i64-eq
                    error.input
                    position
                    "error input position")
                  (test.assert-i64-eq
                    error.output
                    written
                    "error output position")
                  (let
                    [before : i64 state.work]
                    [again : deflate.DeflateStep
                      (deflate.step!
                        (&mut state)
                        input
                        (byte_buf.as-mut-bytes (&mut out))
                        false)]
                    (test.assert-i64-eq
                      again.consumed
                      0
                      "failed state consumes nothing")
                    (test.assert-i64-eq
                      again.produced
                      0
                      "failed state emits nothing")
                    (test.assert-i64-eq state.work before "failed work stable")
                    (match again.status
                      [(deflate.Error repeated)
                        (test.assert-i64-eq
                          (kind-code (& repeated.kind))
                          expected
                          "sticky error kind")
                        (test.assert-i64-eq
                          repeated.input
                          position
                          "sticky input position")
                        (test.assert-i64-eq
                          repeated.output
                          written
                          "sticky output position")]
                      [_ (test.assert-true false "failure remains terminal")]))
                  (test.assert-i64-eq
                    (profile.alloc-total)
                    allocation
                    "error path allocates nothing")
                  (return state.work)])))
          0)])))

(define (assert-errors) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (for [fixture (iterator.range 0 23)]
      (with-arena
        malformed
        (let
          [input : byte_buf.ByteBuf (malformed-input fixture)]
          [expected : i64 (malformed-kind fixture)]
          [position : i64 (malformed-position fixture)]
          [work : i64
            (error-stream
              (byte_buf.as-bytes (& input))
              (& limits)
              input.len
              expected)]
          (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
            [(deflate.DeflateDecodeOk _)
              (test.assert-true false "one-shot malformed completion")]
            [(deflate.DeflateDecodeErr error)
              (test.assert-i64-eq
                (kind-code (& error.kind))
                expected
                "one-shot malformed kind")
              (when
                (>= position 0)
                (test.assert-i64-eq
                  error.input
                  position
                  "malformed one-shot error position"))])
          (for [split (iterator.range 0 (+ input.len 1))]
            (test.assert-i64-eq
              (error-stream
                (byte_buf.as-bytes (& input))
                (& limits)
                split
                expected)
              work
              "malformed chunk-independent work")))))
    (for [fixture (iterator.range 0 21)]
      (when
        (small-fixture? fixture)
        (with-arena
          truncated
          (let
            [input : byte_buf.ByteBuf (fixture-input fixture)]
            [member : i64 (- input.len 2)]
            (for [prefix (iterator.range 0 member)]
              (match (deflate.decode
                (byte_buf.bytes-slice-view
                  (byte_buf.as-bytes (& input))
                  0
                  prefix)
                (& limits))
                [(deflate.DeflateDecodeOk _)
                  (test.assert-true false "truncated prefix completed")]
                [(deflate.DeflateDecodeErr error)
                  (test.assert-i64-eq
                    (kind-code (& error.kind))
                    5
                    "every valid prefix truncates")]))))))))

(define (assert-limits) : unit
  (let
    [hello : byte_buf.ByteBuf (hex-bytes "cb48cdc9c90700")]
    [bomb : byte_buf.ByteBuf (hex-bytes "731c0500")]
    (for [mode (iterator.range 0 7)]
      (let
        [limits : deflate.DeflateLimits (deflate.default-limits)]
        [expected : i64
          (cond
            [(= mode 0) 9]
            [(= mode 1) 10]
            [(= mode 2) 12]
            [(= mode 3) 13]
            [(= mode 4) 13]
            [(= mode 5) 11]
            [else 0])]
        (cond
          [(= mode 0) (set! limits.max-input 1)]
          [(= mode 1) (set! limits.max-output 4)]
          [(= mode 2) (set! limits.max-work 33492)]
          [(= mode 3)
            (set! limits.ratio 0)
            (set! limits.startup-bytes 4)]
          [(= mode 4)
            (set! limits.ratio 1)
            (set! limits.startup-bytes 0)]
          [(= mode 5) (set! limits.window-bytes 0)]
          [else (set! limits.window-bytes 32769)])
        (if (or (= mode 4) (= mode 5))
          (let
            [work : i64
              (error-stream
                (byte_buf.as-bytes (& bomb))
                (& limits)
                bomb.len
                expected)]
            (for [split (iterator.range 0 (+ bomb.len 1))]
              (test.assert-i64-eq
                (error-stream
                  (byte_buf.as-bytes (& bomb))
                  (& limits)
                  split
                  expected)
                work
                "bomb limit work stable")))
          (let
            [work : i64
              (error-stream
                (byte_buf.as-bytes (& hello))
                (& limits)
                hello.len
                expected)]
            (for [split (iterator.range 0 (+ hello.len 1))]
              (test.assert-i64-eq
                (error-stream
                  (byte_buf.as-bytes (& hello))
                  (& limits)
                  split
                  expected)
                work
                "limit work stable"))))))
    (let
      [limits : deflate.DeflateLimits
        (deflate.DeflateLimits
          9223372036854775807
          9223372036854775807
          0
          9223372036854775807
          9223372036854775807
          0)]
      (test.assert-true
        (deflate.deflate-ratio-allows? (& limits) 1 9223372036854775807)
        "ratio multiplication cannot overflow")
      (set! limits.ratio 0)
      (set! limits.startup-bytes 9223372036854775807)
      (test.assert-true
        (deflate.deflate-ratio-allows? (& limits) 0 9223372036854775807)
        "maximum startup allowance")
      (set! limits.startup-bytes 5)
      (match (deflate.decode (byte_buf.as-bytes (& hello)) (& limits))
        [(deflate.DeflateDecodeOk decoded)
          (test.assert-i64-eq decoded.bytes.len 5 "zero-window literals")]
        [_ (test.assert-true false "exact startup boundary succeeds")]))
    (let
      [limits : deflate.DeflateLimits (deflate.default-limits)]
      [empty : byte_buf.ByteBuf (hex-bytes "0300")]
      (set! limits.max-output 0)
      (match (deflate.decode (byte_buf.as-bytes (& empty)) (& limits))
        [(deflate.DeflateDecodeOk decoded)
          (test.assert-i64-eq decoded.bytes.len 0 "zero output empty member")]
        [_ (test.assert-true false "zero output limit accepts empty member")])
      (set! limits.max-work 0)
      (match (deflate.decoder-new (& limits))
        [(deflate.DeflateNewErr error)
          (test.assert-i64-eq
            (kind-code (& error.kind))
            12
            "initial work checked")]
        [_ (test.assert-true false "initial allocation work bounded")]))))

(define (assert-public-state) : unit
  (for [mode (iterator.range 0 13)]
    (match (new-decoder)
      [(deflate.DeflateNewErr _) (test.assert-true false "forged state setup")]
      [(deflate.DeflateNewOk state)
        (let
          [input : byte_buf.ByteBuf (hex-bytes "0300")]
          [output : byte_buf.ByteBuf (repeat-byte 4 (cast 204 : u8))]
          [expected : i64 (cond [(= mode 12) 7] [(>= mode 9) 8] [else 1])]
          (cond
            [(= mode 0) (set! state.phase -1)]
            [(= mode 1) (set! state.bit-count 64)]
            [(= mode 2) (set! state.field-read 63)]
            [(= mode 3) (set! state.history (byte_buf.new))]
            [(= mode 4) (set! state.history-position 32768)]
            [(= mode 5) (set! state.history.len -1)]
            [(= mode 6)
              (set! state.phase 16)
              (set! state.pending-length 0)]
            [(= mode 7) (set! state.symbol-index -1)]
            [(= mode 8)
              (set! state.phase 11)
              (set! (array-ref state.tree-counts 0) 1)
              (set! (array-ref state.tree-counts 1) 9223372036854775807)]
            [(= mode 9)
              (set! state.limits.max-input 9223372036854775807)
              (set! state.total-input 9223372036854775807)]
            [(= mode 10)
              (set! state.limits.max-output 9223372036854775807)
              (set! state.total-output 9223372036854775807)
              (set! state.phase 15)
              (set! state.pending-value 65)]
            [(= mode 11)
              (set! state.limits.max-work 9223372036854775807)
              (set! state.work 9223372036854775807)]
            [else
              ;; Finishing forged distance extra bits gives InvalidDistance;
              ;; the resulting distance exceeds the active scalar range.
              (set! state.phase 14)
              (set! state.pending-length 3)
              (set! state.pending-distance 32768)
              (set! state.repeat-extra 13)
              (set! state.field-read 13)
              (set! state.field-value 8191)])
          (let
            [result : deflate.DeflateStep
              (deflate.step!
                (&mut state)
                (byte_buf.as-bytes (& input))
                (byte_buf.as-mut-bytes (&mut output))
                true)]
            (test.assert-i64-eq result.produced 0 "forged state never emits")
            (match result.status
              [(deflate.Error error)
                (test.assert-i64-eq
                  (kind-code (& error.kind))
                  expected
                  "forged/overflow state typed error")
                (for [retry (iterator.range 0 2)]
                  (let
                    [work : i64 state.work]
                    [again : deflate.DeflateStep
                      (deflate.step!
                        (&mut state)
                        (byte_buf.as-bytes (& input))
                        (byte_buf.bytes-mut-slice-view
                          (byte_buf.as-mut-bytes (&mut output))
                          0
                          retry)
                        (= retry 0))]
                    (test.assert-i64-eq again.consumed 0 "forged retry input")
                    (test.assert-i64-eq again.produced 0 "forged retry output")
                    (test.assert-i64-eq state.work work "forged retry work")
                    (match again.status
                      [(deflate.Error repeated)
                        (test.assert-i64-eq
                          (kind-code (& repeated.kind))
                          expected
                          "forged sticky kind")
                        (test.assert-i64-eq
                          repeated.input
                          error.input
                          "forged sticky input")
                        (test.assert-i64-eq
                          repeated.output
                          error.output
                          "forged sticky output")]
                      [_
                        (test.assert-true false "forged failure stays terminal")])))]
              [_ (test.assert-true false "forged state refused")])))])))

(define (stored-boundary-input) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 65542)]
    (set! (array-ref slots 0) (cast 1 : u8))
    (set! (array-ref slots 1) (cast 255 : u8))
    (set! (array-ref slots 2) (cast 255 : u8))
    (for [index (iterator.range 0 65535)]
      (set!
        (array-ref slots (+ 5 index))
        (cast (% (+ (* index 73) 19) 256) : u8)))
    (set! (array-ref slots 65540) (cast 165 : u8))
    (set! (array-ref slots 65541) (cast 90 : u8))
    (byte_buf.from-array slots)))

(define (stored-boundary-output) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 65535)]
    (for [index (iterator.range 0 65535)]
      (set! (array-ref slots index) (cast (% (+ (* index 73) 19) 256) : u8)))
    (byte_buf.from-array slots)))

(define (assert-stored-boundary) : unit
  (with-arena
    stored
    (let
      [input : byte_buf.ByteBuf (stored-boundary-input)]
      [expected : byte_buf.ByteBuf (stored-boundary-output)]
      [work : i64
        (stream-case
          (byte_buf.as-bytes (& input))
          (byte_buf.as-bytes (& expected))
          input.len
          4096
          false
          65540)]
      (for [split (iterator.range 0 7)]
        (test.assert-i64-eq
          (stream-case
            (byte_buf.as-bytes (& input))
            (byte_buf.as-bytes (& expected))
            split
            7
            true
            65540)
          work
          "maximum stored block split")))))

(define (empty-block-chain [count : i64]) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 (* count 5))]
    (for [index (iterator.range 0 count)]
      (set!
        (array-ref slots (* index 5))
        (cast
          (if (= index (- count 1))
            1
            0)
          : u8))
      (set! (array-ref slots (+ (* index 5) 3)) (cast 255 : u8))
      (set! (array-ref slots (+ (* index 5) 4)) (cast 255 : u8)))
    (byte_buf.from-array slots)))

(define (assert-empty-chain-work) : unit
  (let
    [input : byte_buf.ByteBuf (empty-block-chain 200)]
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (set! limits.max-output 0)
    (set! limits.max-work 33689)
    (let
      [work : i64
        (error-stream (byte_buf.as-bytes (& input)) (& limits) input.len 12)]
      (test.assert-true (<= work limits.max-work) "empty chain work bounded")
      (for [split (iterator.range 0 12)]
        (test.assert-i64-eq
          (error-stream (byte_buf.as-bytes (& input)) (& limits) split 12)
          work
          "empty block chain chunk-independent work")))))

(define (assert-chunk-scopes) : unit
  (match (new-decoder)
    [(deflate.DeflateNewErr _) (test.assert-true false "scoped chunks setup")]
    [(deflate.DeflateNewOk state)
      (with-arena
        first-chunk
        (let
          [input : byte_buf.ByteBuf (hex-bytes "731c")]
          [out : byte_buf.ByteBuf (repeat-byte 1 (cast 0 : u8))]
          [result : deflate.DeflateStep
            (deflate.step!
              (&mut state)
              (byte_buf.as-bytes (& input))
              (byte_buf.as-mut-bytes (&mut out))
              false)]
          (test.assert-i64-eq result.consumed 2 "first scoped chunk consumed")
          (test.assert-i64-eq
            result.produced
            1
            "first scoped chunk emitted literal")
          (match result.status
            [(deflate.NeedInput) unit]
            [_ (test.assert-true false "partial symbol survives chunk drop")])))
      (with-arena
        second-chunk
        (let
          [input : byte_buf.ByteBuf (hex-bytes "0500")]
          [out : byte_buf.ByteBuf (repeat-byte 258 (cast 0 : u8))]
          [result : deflate.DeflateStep
            (deflate.step!
              (&mut state)
              (byte_buf.as-bytes (& input))
              (byte_buf.as-mut-bytes (&mut out))
              true)]
          (test.assert-i64-eq result.produced 258 "history survives chunk drop")
          (for [index (iterator.range 0 258)]
            (test.assert-i64-eq
              (cast (byte_buf.ref out index) : i64)
              65
              "cross-arena match byte"))
          (match result.status
            [(deflate.Done) unit]
            [_ (test.assert-true false "scoped second chunk completes")])))
      (test.assert-i64-eq
        state.total-output
        259
        "outer decoder retains only history")]))

(define (assert-initial-allocation) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [before : i64 (profile.alloc-total)]
    (match (deflate.decoder-new (& limits))
      [(deflate.DeflateNewErr _) (test.assert-true false "allocation setup")]
      [(deflate.DeflateNewOk state)
        (let
          [allocated : i64 (- (profile.alloc-total) before)]
          (test.assert-true (> allocated 0) "allocation counter is active")
          (test.assert-true
            (<= allocated 38856)
            "fixed retained workspace bound")
          (test.assert-i64-eq state.work 33489 "fixed initial work charge"))])
    (set! limits.window-bytes -1)
    (let
      [rejected : i64 (profile.alloc-total)]
      (match (deflate.decoder-new (& limits))
        [(deflate.DeflateNewErr error)
          (test.assert-i64-eq
            (kind-code (& error.kind))
            0
            "invalid limit typed error")]
        [_ (test.assert-true false "invalid limit refused")])
      (test.assert-i64-eq
        (profile.alloc-total)
        rejected
        "invalid limits allocate nothing"))))

(define (assert-cancellation) : unit
  (let
    [before : i64 (profile.alloc-live)]
    (for [index (iterator.range 0 64)]
      (with-arena
        cancelled
        (match (new-decoder)
          [(deflate.DeflateNewErr _)
            (test.assert-true false "cancelled decoder setup")]
          [(deflate.DeflateNewOk state)
            (let
              [input : byte_buf.ByteBuf (hex-bytes "73")]
              [out : byte_buf.ByteBuf (repeat-byte 0 (cast 0 : u8))]
              [result : deflate.DeflateStep
                (deflate.step!
                  (&mut state)
                  (byte_buf.as-bytes (& input))
                  (byte_buf.as-mut-bytes (&mut out))
                  false)]
              (match result.status
                [(deflate.NeedInput) unit]
                [_ (test.assert-true false "cancel partial symbol")]))])))
    (test.assert-i64-eq
      (profile.alloc-live)
      before
      "partial decoder arena fully released")))

(defstruct RandomInput
  (bytes byte_buf.ByteBuf)
  (seed i64))

(define (random-input [seed : i64] [length : i64] [force : bool]) : RandomInput
  (let
    [next : i64 seed]
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    (for [index (iterator.range 0 length)]
      (set! next (% (+ (* next 1664525) 1013904223) 4294967296))
      (set! (array-ref slots index) (cast (shr next 24) : u8)))
    (when
      force
      (set!
        (array-ref slots 0)
        (cast (bit-or (cast (array-ref slots 0) : i64) 7) : u8)))
    (RandomInput (byte_buf.from-array slots) next)))

(define (assert-random-bounds) : unit
  (let
    [seed : i64 7785]
    [limits : deflate.DeflateLimits
      (deflate.DeflateLimits 64 256 32 100000 8 32)]
    (for [case (iterator.range 0 128)]
      (with-arena
        random-case
        (let
          [length : i64 (+ 1 (% case 24))]
          [input : RandomInput (random-input seed length (= (% case 2) 0))]
          (set! seed input.seed)
          (match (deflate.decode (byte_buf.as-bytes (& input.bytes)) (& limits))
            [(deflate.DeflateDecodeOk decoded)
              (test.assert-true
                (<= decoded.consumed length)
                "random exact input bound")
              (test.assert-true
                (<= decoded.bytes.len 256)
                "random output bound")]
            [(deflate.DeflateDecodeErr error)
              (when
                (= (% case 2) 0)
                (test.assert-i64-eq
                  (kind-code (& error.kind))
                  6
                  "random forced reserved block"))]))))))

(define (all-code-input) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push
      (hex-bytes
        "731c05a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46c1281805a360148c8251300a46812310800018400014c0001c2000124006280015a001748001300116801de000b8011e801f100084011180784002201d9001c8071400ca011500f5010d00ed011d00fdc10080810783000c7e3004c0d007c3000c7f3002c08807a3000880108880184800492005a4810c201bc801f281024071a004501ea800a81ea801a81f6800d07ca00540fb810e00ba1fe801a0ff8101000c7f600400e31f980080e91f980180f91f580000cb7f600500acff810d0060fb1fd80100f6ff810300c0f17fe0040070fe1fb80000b8fe1fb80100b8ff1f780000f0fc7fe00500c0fbff01")
      (cast 165 : u8))
    (cast 90 : u8)))

(define (assert-all-codes) : unit
  (with-arena
    all-codes
    (let
      [input : byte_buf.ByteBuf (all-code-input)]
      [expected : byte_buf.ByteBuf (repeat-byte 36321 (cast 65 : u8))]
      [cuts : (Array i64 191)
        (array
          0
          1
          208
          210
          211
          212
          213
          214
          215
          216
          217
          218
          219
          220
          221
          222
          223
          224
          225
          226
          227
          228
          229
          230
          231
          232
          233
          234
          235
          236
          237
          238
          239
          240
          241
          242
          243
          244
          245
          246
          247
          248
          249
          250
          251
          252
          253
          254
          255
          256
          257
          258
          259
          260
          261
          262
          263
          264
          265
          266
          267
          268
          269
          270
          271
          272
          273
          274
          275
          276
          277
          279
          281
          282
          283
          284
          285
          286
          288
          290
          291
          292
          293
          294
          295
          297
          298
          299
          300
          301
          302
          303
          304
          305
          306
          307
          308
          309
          310
          311
          312
          313
          314
          315
          316
          317
          318
          319
          320
          321
          322
          323
          324
          325
          326
          327
          328
          329
          330
          331
          332
          333
          334
          335
          336
          337
          338
          340
          342
          343
          344
          345
          346
          347
          348
          349
          351
          352
          353
          354
          355
          356
          358
          359
          360
          361
          363
          364
          365
          366
          368
          369
          370
          371
          373
          374
          375
          376
          378
          379
          381
          382
          383
          384
          386
          387
          389
          390
          392
          393
          395
          397
          398
          400
          401
          403
          404
          406
          407
          409
          410
          412
          413
          415
          416
          418
          419
          421
          422
          425
          429)]
      [work : i64
        (stream-case
          (byte_buf.as-bytes (& input))
          (byte_buf.as-bytes (& expected))
          input.len
          4096
          false
          429)]
      (for [index (iterator.range 0 191)]
        (test.assert-i64-eq
          (stream-case
            (byte_buf.as-bytes (& input))
            (byte_buf.as-bytes (& expected))
            (array-ref cuts index)
            7
            true
            429)
          work
          "all-code field boundary split")))))

;; Prime a fresh decoder with `prefix` container bytes and a preset history,
;; then decode one fixed block. Returns -1 for Done with `expected` output,
;; the step's error kind, or 100 plus the kind of a refused priming.
(define (primed-case
  [limits : (& limits deflate.DeflateLimits)]
  [prefix : i64]
  [dictionary : String]
  [body : String]
  [expected : String]) : i64
  (match (deflate.decoder-new limits)
    [(deflate.DeflateNewErr _) -2]
    [(deflate.DeflateNewOk state)
      (let
        [history : byte_buf.ByteBuf (hex-bytes dictionary)]
        [input : byte_buf.ByteBuf (hex-bytes body)]
        [out : byte_buf.ByteBuf (repeat-byte 8 (cast 0 : u8))]
        [initial : i64 state.work]
        (if (deflate.decoder-prime!
          (&mut state)
          prefix
          (byte_buf.as-bytes (& history)))
          (begin
            (test.assert-i64-eq
              state.total-input
              prefix
              "prefix counts as input")
            (test.assert-i64-eq
              state.work
              (+ initial (+ prefix history.len))
              "prefix and dictionary bytes are charged")
            (let
              [result : deflate.DeflateStep
                (deflate.step!
                  (&mut state)
                  (byte_buf.as-bytes (& input))
                  (byte_buf.as-mut-bytes (&mut out))
                  true)]
              (match result.status
                [(deflate.Done)
                  (set! out.len result.produced)
                  (let
                    [actual : String (byte_buf.to-string out)]
                    (test.assert-string-eq
                      (& actual)
                      (& expected)
                      "primed output"))
                  -1]
                [(deflate.Error error) (kind-code (& error.kind))]
                [_ -3])))
          (let
            [result : deflate.DeflateStep
              (deflate.step!
                (&mut state)
                (byte_buf.as-bytes (& input))
                (byte_buf.as-mut-bytes (&mut out))
                true)]
            (test.assert-i64-eq
              state.work
              initial
              "failed priming charges nothing")
            (test.assert-i64-eq
              state.total-input
              0
              "failed priming accepts nothing")
            (match result.status
              [(deflate.Error error)
                (test.assert-i64-eq
                  error.input
                  (if (> prefix limits.max-input)
                    limits.max-input
                    prefix)
                  "failed priming position")
                (+ 100 (kind-code (& error.kind)))]
              [_ 99]))))]))

;; Body 032200 is length 3 at distance 3; 036200 is length 3 at distance 4.
(define (assert-preset-history) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [small : deflate.DeflateLimits (deflate.default-limits)]
    (test.assert-i64-eq
      (primed-case (& limits) 0 "616263" "032200" "abc")
      -1
      "reference reaches the first dictionary byte")
    (test.assert-i64-eq
      (primed-case (& limits) 0 "616263" "036200" "")
      7
      "reference before the dictionary")
    (test.assert-i64-eq
      (primed-case (& limits) 6 "616263" "032200" "abc")
      -1
      "container prefix")
    (set! small.window-bytes 3)
    (test.assert-i64-eq
      (primed-case (& small) 0 "78797a616263" "032200" "abc")
      -1
      "long dictionary keeps its window tail")
    (set! small.window-bytes 0)
    (test.assert-i64-eq
      (primed-case (& small) 0 "616263" "032200" "")
      7
      "no history without a window")
    (set! small.window-bytes 32768)
    (set! small.max-input 5)
    (test.assert-i64-eq
      (primed-case (& small) 6 "616263" "032200" "")
      109
      "prefix beyond the input limit")
    (set! small.max-input 67108864)
    (set! small.max-work 33497)
    (test.assert-i64-eq
      (primed-case (& small) 6 "616263" "032200" "")
      112
      "prefix and dictionary beyond the work limit"))
  (match (new-decoder)
    [(deflate.DeflateNewErr _) (test.assert-true false "non-fresh setup")]
    [(deflate.DeflateNewOk state)
      (let
        [input : byte_buf.ByteBuf (hex-bytes "03")]
        [history : byte_buf.ByteBuf (hex-bytes "616263")]
        [out : byte_buf.ByteBuf (repeat-byte 4 (cast 0 : u8))]
        (deflate.step!
          (&mut state)
          (byte_buf.as-bytes (& input))
          (byte_buf.as-mut-bytes (&mut out))
          false)
        (let
          [work : i64 state.work]
          (test.assert-true
            (not
              (deflate.decoder-prime!
                (&mut state)
                0
                (byte_buf.as-bytes (& history))))
            "started decoder is not primed")
          (test.assert-i64-eq state.work work "refused priming charges nothing")
          (test.assert-i64-eq state.preset 0 "refused priming keeps no history")
          (test.assert-i64-eq state.phase 11 "refused priming keeps the phase")))]))

;; RFC fixed headers (3 bits) and EOB (7 bits), with no inter-block padding.
(define (fixed-empty-chain [count : i64]) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 (/ (+ (* count 10) 7) 8))]
    (for [index (iterator.range 0 count)]
      (for [bit (iterator.range 0 2)]
        (when
          (or (= bit 1) (= index (- count 1)))
          (let
            [position : i64 (+ (* index 10) bit)]
            [byte : i64 (/ position 8)]
            (set!
              (array-ref slots byte)
              (cast
                (bit-or
                  (cast (array-ref slots byte) : i64)
                  (shl 1 (% position 8)))
                : u8))))))
    (byte_buf.from-array slots)))

(define (assert-fixed-reuse) : unit
  (let
    [empty : byte_buf.ByteBuf (hex-bytes "")]
    (for [count (iterator.range 1 34)]
      (with-arena
        fixed-chain
        (let
          [input : byte_buf.ByteBuf (fixed-empty-chain count)]
          [expected : i64 (+ 34543 (+ (* count 10) input.len))]
          (for [split (iterator.range 0 (+ input.len 1))]
            (test.assert-i64-eq
              (stream-case
                (byte_buf.as-bytes (& input))
                (byte_buf.as-bytes (& empty))
                split
                1
                true
                input.len)
              expected
              "fixed preparation charged once across splits")))))
    ;; Two blocks formerly needed 35620 units. The new exact budget is 34566.
    (let
      [input : byte_buf.ByteBuf (fixed-empty-chain 2)]
      (for [budget (iterator.range 0 4)]
        (let
          [limits : deflate.DeflateLimits (deflate.default-limits)]
          (set!
            limits.max-work
            (cond
              [(= budget 0) 34565]
              [(= budget 1) 34566]
              [(= budget 2) 35619]
              [else 35620]))
          (for [split (iterator.range 0 (+ input.len 1))]
            (if (= budget 0)
              (test.assert-i64-eq
                (error-stream (byte_buf.as-bytes (& input)) (& limits) split 12)
                34565
                "one below new fixed budget fails exactly")
              (let
                [actual : RunObservation
                  (observe-run (byte_buf.as-bytes (& input)) (& limits) split 1)]
                (test.assert-i64-eq
                  actual.kind
                  -1
                  "fixed reuse meets exact budget")
                (test.assert-i64-eq
                  actual.input
                  3
                  "new and old fixed budgets complete")
                (test.assert-i64-eq actual.work 34566 "fixed exact budget work")))))))))

;; Empty fixed, the 92 significant bits of fixture 6, then final empty fixed.
;; Work33489+1054+14+112+19+85+258+(94+2*258)=35641; fixed prep once.
;; Only the last header has BFINAL; block boundaries have no padding.
(define (mixed-fixed-dynamic) : byte_buf.ByteBuf
  (let
    [dynamic : byte_buf.ByteBuf (fixture-input 6)]
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 14)]
    (for [bit (iterator.range 0 112)]
      (let
        [value : i64
          (cond
            [(and (>= bit 10) (< bit 102))
              (if (= bit 10)
                0
                (bit-and
                  (shr
                    (cast (byte_buf.ref dynamic (/ (- bit 10) 8)) : i64)
                    (% (- bit 10) 8))
                  1))]
            [(or (= bit 1) (= bit 102) (= bit 103)) 1]
            [else 0])]
        (set!
          (array-ref slots (/ bit 8))
          (cast
            (bit-or
              (cast (array-ref slots (/ bit 8)) : i64)
              (shl value (% bit 8)))
            : u8))))
    (byte_buf.from-array slots)))

(define (assert-mixed-tables) : unit
  (let
    [input : byte_buf.ByteBuf (mixed-fixed-dynamic)]
    [empty : byte_buf.ByteBuf (hex-bytes "")]
    (for [split (iterator.range 0 15)]
      (test.assert-i64-eq
        (stream-case
          (byte_buf.as-bytes (& input))
          (byte_buf.as-bytes (& empty))
          split
          1
          true
          14)
        35641
        "fixed constants survive dynamic table mutation"))))

(defstruct RunObservation
  (kind i64)
  (input i64)
  (output i64)
  (work i64)
  (bytes byte_buf.ByteBuf))

(define (observe-run
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [split : i64]
  [capacity : i64]) : RunObservation
  (match (deflate.decoder-new limits)
    [(deflate.DeflateNewErr error)
      (RunObservation
        (kind-code (& error.kind))
        error.input
        error.output
        0
        (byte_buf.new))]
    [(deflate.DeflateNewOk state)
      (let
        [out : byte_buf.ByteBuf (repeat-byte capacity (cast 204 : u8))]
        [collected : byte_buf.ByteBuf (byte_buf.new)]
        [position : i64 0]
        [front : bool true]
        (for [_call (iterator.range 0 2048)]
          (let
            [end : i64
              (if front
                split
                (byte_buf.bytes-length input))]
            [result : deflate.DeflateStep
              (deflate.step!
                (&mut state)
                (byte_buf.bytes-slice-view input position (- end position))
                (byte_buf.as-mut-bytes (&mut out))
                (not front))]
            (set! position (+ position result.consumed))
            (set!
              collected
              (byte_buf.append-bytes-range
                collected
                (byte_buf.as-bytes (& out))
                0
                result.produced))
            (test.assert-true
              (<= position limits.max-input)
              "run input bounded")
            (test.assert-true
              (<= collected.len limits.max-output)
              "run output bounded")
            (test.assert-true
              (<= state.work limits.max-work)
              "run work bounded")
            (match result.status
              [(deflate.NeedInput)
                (test.assert-true front "explicit EOF is terminal")
                (set! front false)]
              [(deflate.NeedOutput) unit]
              [(deflate.Done)
                (return
                  (RunObservation
                    -1
                    position
                    collected.len
                    state.work
                    collected))]
              [(deflate.Error error)
                (return
                  (RunObservation
                    (kind-code (& error.kind))
                    error.input
                    error.output
                    state.work
                    collected))])))
        (test.assert-true false "bounded run terminates")
        (RunObservation -2 position collected.len state.work collected))]))

(define (assert-observation
  [actual : (& actual RunObservation)]
  [expected : (& expected RunObservation)]) : unit
  (test.assert-i64-eq actual.kind expected.kind "split failure kind")
  (test.assert-i64-eq actual.input expected.input "split failure input")
  (test.assert-i64-eq actual.output expected.output "split failure output")
  (test.assert-i64-eq actual.work expected.work "split exact work")
  (test.assert-i64-eq
    actual.bytes.len
    expected.bytes.len
    "split partial output size")
  (for [index (iterator.range 0 actual.bytes.len)]
    (test.assert-i64-eq
      (cast (byte_buf.ref actual.bytes index) : i64)
      (cast (byte_buf.ref expected.bytes index) : i64)
      "split partial output byte")))

(define (assert-run-splits
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]) : unit
  (with-arena
    reference
    (let
      [expected : RunObservation
        (observe-run input limits (byte_buf.bytes-length input) 512)]
      (match (deflate.decode input limits)
        [(deflate.DeflateDecodeOk decoded)
          (test.assert-i64-eq expected.kind -1 "one-shot and stream finish")
          (test.assert-i64-eq
            decoded.consumed
            expected.input
            "one-shot exact input")
          (test.assert-i64-eq
            decoded.bytes.len
            expected.output
            "one-shot exact output")
          (for [index (iterator.range 0 decoded.bytes.len)]
            (test.assert-i64-eq
              (cast (byte_buf.ref decoded.bytes index) : i64)
              (cast (byte_buf.ref expected.bytes index) : i64)
              "one-shot bytes"))]
        [(deflate.DeflateDecodeErr error)
          (test.assert-i64-eq
            (kind-code (& error.kind))
            expected.kind
            "one-shot failure kind")
          (test.assert-i64-eq
            error.input
            expected.input
            "one-shot failure input")
          (test.assert-i64-eq
            error.output
            expected.output
            "one-shot failure output")])
      (for [split (iterator.range 0 (+ (byte_buf.bytes-length input) 1))]
        (for [mode (iterator.range 0 3)]
          (with-arena
            split-case
            (let
              [actual : RunObservation
                (observe-run
                  input
                  limits
                  split
                  (cond [(= mode 0) 1] [(= mode 1) 7] [else 512]))]
              (assert-observation (& actual) (& expected)))))))))

(define (assert-work-boundaries [input : (& input bytes)] [end : i64]) : unit
  (for [budget (iterator.range 0 end)]
    (with-arena
      work-boundary
      (let
        [limits : deflate.DeflateLimits (deflate.default-limits)]
        (set! limits.window-bytes 1)
        (set! limits.max-work (+ 722 budget))
        (assert-run-splits input (& limits))))))

(define (assert-resource-boundaries [input : (& input bytes)] [end : i64]) : unit
  (for [mode (iterator.range 0 4)]
    (for [bound (iterator.range 0 end)]
      (with-arena
        resource-boundary
        (let
          [limits : deflate.DeflateLimits (deflate.default-limits)]
          (set! limits.window-bytes 1)
          (cond
            [(= mode 0) (set! limits.max-input bound)]
            [(= mode 1) (set! limits.max-output bound)]
            [(= mode 2)
              (set! limits.ratio 0)
              (set! limits.startup-bytes bound)]
            [else
              (set! limits.ratio 1)
              (set! limits.startup-bytes bound)])
          (assert-run-splits input (& limits)))))))

(define (assert-run-boundaries) : unit
  (let
    [stored : byte_buf.ByteBuf (hex-bytes "010500faff68656c6c6f")]
    [matched : byte_buf.ByteBuf (hex-bytes "731c0500")]
    (assert-work-boundaries (byte_buf.as-bytes (& stored)) 100)
    (assert-work-boundaries (byte_buf.as-bytes (& matched)) 1352)
    (assert-resource-boundaries (byte_buf.as-bytes (& stored)) 12)
    (assert-resource-boundaries (byte_buf.as-bytes (& matched)) 261)))

(define (assert-run-mutations) : unit
  (let
    [seed : i64 9531]
    (for [case (iterator.range 0 96)]
      (with-arena
        mutation
        (let
          [input : byte_buf.ByteBuf
            (fixture-input
              (cond
                [(= (% case 4) 0) 3]
                [(= (% case 4) 1) 4]
                [(= (% case 4) 2) 7]
                [else 9]))]
          [limits : deflate.DeflateLimits
            (deflate.DeflateLimits 64 512 32 100000 8 32)]
          (set! seed (% (+ (* seed 1664525) 1013904223) 4294967296))
          (let
            [index : i64 (% seed (- input.len 2))]
            (set!
              (array-ref input.slots index)
              (cast
                (bit-xor
                  (cast (array-ref input.slots index) : i64)
                  (shl 1 (% (shr seed 16) 8)))
                : u8)))
          (assert-run-splits (byte_buf.as-bytes (& input)) (& limits)))))))

(define (credit-edge [index : i64]) : i64
  (cond
    [(= index 0) 0]
    [(= index 1) 1]
    [(= index 2) 2]
    [else 9223372036854775807]))

(define (assert-credit-ceiling) : unit
  (for [ratio (iterator.range 0 4)]
    (for [startup (iterator.range 0 4)]
      (for [input (iterator.range 0 4)]
        (let
          [limits : deflate.DeflateLimits (deflate.default-limits)]
          (set! limits.max-output 9223372036854775807)
          (set! limits.ratio (credit-edge ratio))
          (set! limits.startup-bytes (credit-edge startup))
          (let
            [ceiling : i64
              (deflate.deflate-output-ceiling (& limits) (credit-edge input))]
            (test.assert-true
              (deflate.deflate-ratio-allows?
                (& limits)
                (credit-edge input)
                ceiling)
              "saturated ceiling satisfies division-based ratio")
            (when
              (< ceiling 9223372036854775807)
              (test.assert-true
                (not
                  (deflate.deflate-ratio-allows?
                    (& limits)
                    (credit-edge input)
                    (+ ceiling 1)))
                "first byte above ceiling exceeds ratio"))))))))

;; A fixed literal A, length258/distance1 and EOB. The match has accepted
;; three bytes: ratio2/startup253 permits exactly259 output bytes; 252 permits258.
(define (assert-ratio-precision) : unit
  (let
    [input : byte_buf.ByteBuf (hex-bytes "731c0500")]
    (for [startup (iterator.range 252 254)]
      (let
        [limits : deflate.DeflateLimits (deflate.default-limits)]
        (set! limits.ratio 2)
        (set! limits.startup-bytes startup)
        (for [split (iterator.range 0 5)]
          (let
            [actual : RunObservation
              (observe-run (byte_buf.as-bytes (& input)) (& limits) split 7)]
            (test.assert-i64-eq
              actual.output
              (+ startup 6)
              "ratio2 exact emission boundary")
            (test.assert-i64-eq
              actual.input
              (if (= startup 252)
                3
                4)
              "ratio2 input offset")
            (test.assert-i64-eq
              actual.kind
              (if (= startup 252)
                13
                -1)
              "ratio2 first excess byte")
            (if (= startup 252)
              (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
                [(deflate.DeflateDecodeErr error)
                  (test.assert-i64-eq
                    (kind-code (& error.kind))
                    13
                    "one-shot ratio2 kind")
                  (test.assert-i64-eq error.input 3 "one-shot ratio2 input")
                  (test.assert-i64-eq error.output 258 "one-shot ratio2 output")]
                [_ (test.assert-true false "ratio2 excess must fail")])
              (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
                [(deflate.DeflateDecodeOk decoded)
                  (test.assert-i64-eq
                    decoded.bytes.len
                    259
                    "ratio2 equality succeeds")]
                [_ (test.assert-true false "ratio2 equality must pass")]))))))))

;; Independent RFC count: init33489 + input16 + significant bits122 + output3
;; + clear19 + code tree85 + materialize258 + final trees(94+2*258) =34602.
;; Repeat codes16/17/18 materialize6,6,138,99,3 lengths, respectively.
(define (assert-dynamic-work) : unit
  (let
    [input : byte_buf.ByteBuf (hex-bytes "0500370900302c7b27f52ff62870ef03")]
    [expected : byte_buf.ByteBuf (hex-bytes "000e0f")]
    (for [split (iterator.range 0 17)]
      (test.assert-i64-eq
        (stream-case
          (byte_buf.as-bytes (& input))
          (byte_buf.as-bytes (& expected))
          split
          1
          true
          16)
        34602
        "absolute dynamic repeat work")
      (for [budget (iterator.range 34601 34603)]
        (let
          [limits : deflate.DeflateLimits (deflate.default-limits)]
          (set! limits.max-work budget)
          (let
            [actual : RunObservation
              (observe-run (byte_buf.as-bytes (& input)) (& limits) split 1)]
            (test.assert-i64-eq
              actual.kind
              (if (= budget 34601)
                12
                -1)
              "dynamic N/N-1 budget")
            (test.assert-i64-eq
              actual.work
              budget
              "dynamic exact charged budget")
            (test.assert-i64-eq actual.input 16 "dynamic budget input")
            (test.assert-i64-eq actual.output 3 "dynamic budget output")))))))

;; RFC dynamic alphabet: literal0=10, EOB=11, length285=0; distance0=0.
;; 106 header bits, literal0, 16384 length258/distance1 pairs and EOB:
;; 32878 significant bits, 4110 input bytes, 4227073 zero output bytes.
(define (near-maximum-ratio-input) : byte_buf.ByteBuf
  (let
    [prefix : byte_buf.ByteBuf (hex-bytes "edc0010900000080a0feafee8806")]
    [out : byte_buf.ByteBuf (repeat-byte 4112 (cast 0 : u8))]
    (for [index (iterator.range 0 prefix.len)]
      (set! (array-ref out.slots index) (byte_buf.ref prefix index)))
    (set! (array-ref out.slots 4109) (cast 48 : u8))
    (set! (array-ref out.slots 4110) (cast 165 : u8))
    (set! (array-ref out.slots 4111) (cast 90 : u8))
    out))

(define (assert-default-ratio-policy) : unit
  (with-arena
    ratio-policy
    (let
      [input : byte_buf.ByteBuf (near-maximum-ratio-input)]
      [limits : deflate.DeflateLimits (deflate.default-limits)]
      (test.assert-i64-eq limits.ratio 1024 "deliberate default ratio")
      (test.assert-i64-eq limits.startup-bytes 1024 "default startup")
      (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
        [(deflate.DeflateDecodeErr error)
          (test.assert-i64-eq
            (kind-code (& error.kind))
            13
            "valid high ratio is a typed limit error")
          ;; Match7426 has consumed14960 bits and accepted1870 bytes.
          (test.assert-i64-eq error.input 1870 "default ratio input offset")
          (test.assert-i64-eq
            error.output
            1915904
            "default ratio output offset")]
        [_ (test.assert-true false "default rejects near-maximum ratio")])
      (for [choice (iterator.range 0 4)]
        (let
          [actual : RunObservation
            (observe-run
              (byte_buf.as-bytes (& input))
              (& limits)
              (cond
                [(= choice 0) 0]
                [(= choice 1) 13]
                [(= choice 2) 1870]
                [else 4109])
              4096)]
          (test.assert-i64-eq actual.kind 13 "stream default ratio error")
          (test.assert-i64-eq actual.input 1870 "stream default input offset")
          (test.assert-i64-eq
            actual.output
            1915904
            "stream default output offset")))
      (set! limits.ratio 1032)
      (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
        [(deflate.DeflateDecodeOk decoded)
          (test.assert-i64-eq
            decoded.consumed
            4110
            "raised ratio preserves suffix")
          (test.assert-i64-eq
            decoded.bytes.len
            4227073
            "raised ratio accepts whole member")
          (for [index (iterator.range 0 decoded.bytes.len)]
            (test.assert-i64-eq
              (cast (byte_buf.ref decoded.bytes index) : i64)
              0
              "high ratio oracle byte"))]
        [_
          (test.assert-true false "explicit raised ratio accepts valid stream")]))))

(defstruct NegativeFixture
  (hex String)
  (kind i64)
  (input i64)
  (output i64))

;; Fixed seed9532: checked field mutations of valid stored/fixed members.
;; Expected kinds and byte offsets follow RFC bit positions, independently of
;; this decoder. Every base decodes and every mutation is rejected by zlib1.3.2.
(define (negative-fixture [index : i64]) : NegativeFixture
  (cond
    [(= index 0) (NegativeFixture "010100faff6ba55a" 2 5 0)]
    [(= index 1) (NegativeFixture "010200fdfbce4da55a" 2 5 0)]
    [(= index 2) (NegativeFixture "010300f8ffd5fa72a55a" 2 5 0)]
    [(= index 3) (NegativeFixture "010400f3ff308e0382a55a" 2 5 0)]
    [(= index 4) (NegativeFixture "010500eaffcf4bf423cfa55a" 2 5 0)]
    [(= index 5) (NegativeFixture "010600fdffe24642cde246a55a" 2 5 0)]
    [(= index 6) (NegativeFixture "010700f8efd9981cfdd9981ca55a" 2 5 0)]
    [(= index 7) (NegativeFixture "010800f7fb642cfa68642cfa68a55a" 2 5 0)]
    [(= index 8) (NegativeFixture "731c0700a55a" 6 3 1)]
    [(= index 9) (NegativeFixture "73741c0300a55a" 6 4 2)]
    [(= index 10) (NegativeFixture "7374741c0700a55a" 6 5 3)]
    [(= index 11) (NegativeFixture "737474741c0300a55a" 6 6 4)]
    [(= index 12) (NegativeFixture "73747474741c0700a55a" 6 7 5)]
    [(= index 13) (NegativeFixture "7374747474741c0300a55a" 6 8 6)]
    [(= index 14) (NegativeFixture "737474747474741c0700a55a" 6 9 7)]
    [(= index 15) (NegativeFixture "73747474747474741c0300a55a" 6 10 8)]
    [(= index 16) (NegativeFixture "73047e00a55a" 6 3 1)]
    [(= index 17) (NegativeFixture "7374043e00a55a" 6 4 2)]
    [(= index 18) (NegativeFixture "737474047e00a55a" 6 5 3)]
    [(= index 19) (NegativeFixture "73747474043e00a55a" 6 6 4)]
    [(= index 20) (NegativeFixture "7374747474047e00a55a" 6 7 5)]
    [(= index 21) (NegativeFixture "737474747474043e00a55a" 6 8 6)]
    [(= index 22) (NegativeFixture "73747474747474047e00a55a" 6 9 7)]
    [else (NegativeFixture "7374747474747474043e00a55a" 6 10 8)]))

(define (assert-negative-corpus) : unit
  (let
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (for [case (iterator.range 0 24)]
      (let
        [fixture : NegativeFixture (negative-fixture case)]
        (with-arena
          negative
          (let
            [input : byte_buf.ByteBuf (hex-bytes fixture.hex)]
            (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
              [(deflate.DeflateDecodeErr error)
                (test.assert-i64-eq
                  (kind-code (& error.kind))
                  fixture.kind
                  "oracle negative kind")
                (test.assert-i64-eq
                  error.input
                  fixture.input
                  "oracle negative input")
                (test.assert-i64-eq
                  error.output
                  fixture.output
                  "oracle negative output")]
              [_ (test.assert-true false "oracle mutation cannot succeed")])
            (for [split (iterator.range 0 (+ input.len 1))]
              (let
                [actual : RunObservation
                  (observe-run (byte_buf.as-bytes (& input)) (& limits) split 1)]
                (test.assert-i64-eq
                  actual.kind
                  fixture.kind
                  "split oracle kind")
                (test.assert-i64-eq
                  actual.input
                  fixture.input
                  "split oracle input")
                (test.assert-i64-eq
                  actual.output
                  fixture.output
                  "split oracle output")
                (test.assert-i64-eq
                  (error-stream
                    (byte_buf.as-bytes (& input))
                    (& limits)
                    split
                    fixture.kind)
                  actual.work
                  "oracle terminal repetition and work")))))))))

(test deflate-ratio-precision (assert-ratio-precision))

(test deflate-dynamic-work (assert-dynamic-work))

(test deflate-default-ratio-policy (assert-default-ratio-policy))

(test deflate-negative-oracle-corpus (assert-negative-corpus))

(test deflate-credit-ceiling (assert-credit-ceiling))

(test deflate-run-boundaries (assert-run-boundaries))

(test deflate-run-mutations (assert-run-mutations))

(test deflate-fixed-reuse (assert-fixed-reuse))

(test deflate-mixed-tables (assert-mixed-tables))

(test deflate-valid-splits (assert-corpus))

(test deflate-malformed-and-truncated (assert-errors))

(test deflate-resource-limits (assert-limits))

(test deflate-forged-state (assert-public-state))

(test deflate-maximum-stored-block (assert-stored-boundary))

(test deflate-empty-block-work (assert-empty-chain-work))

(test deflate-chunk-arena-lifetimes (assert-chunk-scopes))

(test deflate-construction-allocation (assert-initial-allocation))

(test deflate-cancelled-decoder (assert-cancellation))

(test deflate-deterministic-malformed-bounds (assert-random-bounds))

(test deflate-every-length-distance-code (assert-all-codes))

(test deflate-preset-history (assert-preset-history))

(test
  deflate-one-shot-exact-member
  (assert-decode "cb48cdc9c90700aabbcc" "hello" 7))

(define (main) : i64
  (assert-decode "0300" "" 2)
  (assert-decode "010000ffff" "" 5)
  (assert-decode "cb48cdc9c90700aabbcc" "hello" 7)
  (assert-decode "010500faff68656c6c6f" "hello" 10)
  (assert-corpus)
  (assert-errors)
  (assert-limits)
  (assert-public-state)
  (assert-stored-boundary)
  (assert-empty-chain-work)
  (assert-chunk-scopes)
  (assert-initial-allocation)
  (assert-cancellation)
  (assert-random-bounds)
  (assert-all-codes)
  (assert-preset-history)
  (assert-fixed-reuse)
  (assert-mixed-tables)
  (assert-run-boundaries)
  (assert-run-mutations)
  (assert-credit-ceiling)
  (assert-ratio-precision)
  (assert-dynamic-work)
  (assert-default-ratio-policy)
  (assert-negative-corpus)
  42)