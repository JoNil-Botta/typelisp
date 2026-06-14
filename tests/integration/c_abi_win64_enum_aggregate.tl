(defenum Status
  (Ready)
  (Done)
  (Failed))

(defenum SmallChoice
  (SmallNone)
  (SmallSome i64))

(defenum WideChoice
  (WideNone)
  (WideSome u64 f64))

(defenum ReturnChoice
  (ReturnNone)
  (ReturnPair u64 u64))

(extern (status-pick [arg0 : Status] [arg1 : Status] [choose-second : i64]) : Status (:symbol "tl_win64_status_pick"))

(extern status-pick-ptr (:symbol "tl_win64_status_pick_ptr") : (->
  Status
  Status
  i64
  Status))

(extern (small-score [arg : SmallChoice] [bias : i64]) : i64 (:symbol "tl_win64_small_score"))

(extern small-scorer (:symbol "tl_win64_small_score_ptr") : (->
  SmallChoice
  i64
  i64))

(extern (wide-score [arg : WideChoice] [tag : u64]) : i64 (:symbol "tl_win64_wide_score"))

(extern wide-scorer (:symbol "tl_win64_wide_score_ptr") : (->
  WideChoice
  u64
  i64))

(extern (return-choice-make [a : u32] [b : u32] [tag : u64]) : ReturnChoice (:symbol "tl_win64_return_choice_make"))

(extern return-choice-maker (:symbol "tl_win64_return_choice_make_ptr") : (->
  u32
  u32
  u64
  ReturnChoice))

(define (status-rank [s : Status]) : i64
  (match s
    [Ready 1]
    [Done 2]
    [Failed 3]))

(define (return-choice-score [r : ReturnChoice]) : i64
  (match r
    [ReturnNone 0]
    [(ReturnPair lo hi) (+ (cast lo : i64) (cast hi : i64))]))

(define (main) : i64
  (let
    [status-copy : (-> Status Status i64 Status) status-pick-ptr]
    [small-copy : (-> SmallChoice i64 i64) small-scorer]
    [wide-copy : (-> WideChoice u64 i64) wide-scorer]
    [return-copy : (-> u32 u32 u64 ReturnChoice) return-choice-maker]
    [picked : Status (status-pick (Ready) (Done) 1)]
    [picked-via-ptr : Status (status-copy (Ready) (Failed) 1)]
    [small-direct : i64 (small-score (SmallSome 11) 5)]
    [small-via-ptr : i64 (small-copy (SmallNone) 7)]
    [wide-direct : i64
      (wide-score (WideSome (cast 20 : u64) 2.5) (cast 3 : u64))]
    [wide-via-ptr : i64 (wide-copy (WideNone) (cast 4 : u64))]
    [made : ReturnChoice
      (return-choice-make (cast 3 : u32) (cast 4 : u32) (cast 10 : u64))]
    [made-via-ptr : ReturnChoice
      (return-copy (cast 5 : u32) (cast 6 : u32) (cast 2 : u64))]
    (cond
      [(not (= (status-rank picked) 2)) 1]
      [(not (= (status-rank picked-via-ptr) 3)) 2]
      [(not (= small-direct 116)) 3]
      [(not (= small-via-ptr 707)) 4]
      [(not (= wide-direct 48)) 5]
      [(not (= wide-via-ptr 904)) 6]
      [(not (= (return-choice-score made) 117)) 7]
      [(not (= (return-choice-score made-via-ptr) 33)) 8]
      [else 42])))