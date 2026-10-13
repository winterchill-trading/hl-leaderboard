open! Core
open! Async

type t =
  { time_source : Time_source.t
  ; capacity : float
  ; per_ns : float
  ; mutable tokens : float
  ; mutable last : Time_ns.t
  ; sequencer : unit Throttle.Sequencer.t
  ; mutable total_weight : int
  ; mutable total_wait : Time_ns.Span.t
  }

let create ?(time_source = Time_source.wall_clock ()) ?capacity ~refill_per_minute () =
  if refill_per_minute <= 0
  then raise_s [%message "Rate_limit.create: refill_per_minute must be positive"];
  let capacity = Float.of_int (Option.value capacity ~default:refill_per_minute) in
  { time_source = Time_source.read_only time_source
  ; capacity
  ; per_ns = (Float.of_int refill_per_minute /. Time_ns.Span.(to_ns minute))
  ; tokens = capacity
  ; last = Time_source.now time_source
  ; sequencer = Throttle.Sequencer.create ~continue_on_error:true ()
  ; total_weight = 0
  ; total_wait = Time_ns.Span.zero
  }
;;

let hyperliquid ?time_source () = create ?time_source ~refill_per_minute:1200 ()

let refill t =
  let now = Time_source.now t.time_source in
  let elapsed = Time_ns.diff now t.last |> Time_ns.Span.to_ns in
  if Float.(elapsed > 0.)
  then (
    t.tokens <- Float.min t.capacity (t.tokens +. (elapsed *. t.per_ns));
    t.last <- now)
;;

let available t =
  refill t;
  t.tokens
;;

let acquire t ~weight =
  let weight = Float.min t.capacity (Float.of_int (Int.max 0 weight)) in
  Throttle.enqueue t.sequencer (fun () ->
    let rec wait () =
      refill t;
      if Float.(t.tokens >= weight)
      then (
        t.tokens <- t.tokens -. weight;
        t.total_weight <- t.total_weight + Float.to_int weight;
        return ())
      else (
        let missing = weight -. t.tokens in
        (* Round up to a whole millisecond: the timing wheel fires on slot boundaries, and
           an alarm just short of the refill would loop once more. *)
        let span = Time_ns.Span.of_ms (Float.round_up (missing /. t.per_ns /. 1e6)) in
        t.total_wait <- Time_ns.Span.(t.total_wait + span);
        let%bind () = Time_source.after t.time_source span in
        wait ())
    in
    wait ())
;;

let total_weight t = t.total_weight
let total_wait t = t.total_wait

module Weight = struct
  let info = function
    | "l2Book"
    | "allMids"
    | "clearinghouseState"
    | "orderStatus"
    | "spotClearinghouseState"
    | "exchangeStatus" -> 2
    | "userRole" -> 60
    | _ -> 20
  ;;

  let per_items type_ ~items =
    match type_ with
    | "recentTrades"
    | "historicalOrders"
    | "userFills"
    | "userFillsByTime"
    | "fundingHistory"
    | "userFunding"
    | "nonUserFundingUpdates"
    | "twapHistory"
    | "userTwapSliceFills"
    | "userTwapSliceFillsByTime"
    | "delegatorHistory"
    | "delegatorRewards"
    | "validatorStats" -> items / 20
    | _ -> 0
  ;;
end
