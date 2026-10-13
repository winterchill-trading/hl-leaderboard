open! Core
open Hl_protocol
module Column = Parquet.Schema.Column

let ms_to_time ms = Time_ns.of_int_ns_since_epoch (ms * 1_000_000)

let with_tmp path ~f =
  let tmp = path ^ ".tmp" in
  let result = f tmp in
  Core_unix.rename ~src:tmp ~dst:path;
  result
;;

let perf (leader : Dataset.Leader.t) window ~f =
  match leader.row with
  | None -> 0.
  | Some row ->
    (match Board.Row.performance row window with
     | Some p -> f p
     | None -> 0.)
;;

let window_columns =
  List.concat_map Board.Window.all ~f:(fun window ->
    let name =
      match (window : Board.Window.t) with
      | All_time -> "all_time"
      | w -> Board.Window.to_string w
    in
    [ Column.float (name ^ "_pnl") (fun l -> perf l window ~f:(fun p -> p.pnl))
    ; Column.float (name ^ "_roi") (fun l -> perf l window ~f:(fun p -> p.roi))
    ; Column.float (name ^ "_vlm") (fun l -> perf l window ~f:(fun p -> p.vlm))
    ])
;;

let leaders_schema : Dataset.Leader.t Parquet.Schema.t =
  let fill_time ~f (l : Dataset.Leader.t) =
    match f l.fills with
    | Some (fill : User_fill.t) -> ms_to_time fill.time
    | None -> Time_ns.epoch
  in
  Parquet.Schema.create
    ([ Column.utf8 "address" (fun (l : Dataset.Leader.t) -> Address.to_string l.address)
     ; Column.utf8 "display_name" (fun (l : Dataset.Leader.t) ->
         Option.bind l.row ~f:(fun (r : Board.Row.t) -> r.display_name)
         |> Option.value ~default:"")
     ; Column.utf8 "role" (fun (l : Dataset.Leader.t) ->
         Option.value_map l.role ~default:"" ~f:User_role.Role.to_string)
     ; Column.float "account_value" (fun (l : Dataset.Leader.t) ->
         Option.value_map l.row ~default:0. ~f:(fun (r : Board.Row.t) -> r.account_value))
     ]
     @ window_columns
     @ [ Column.int64 "fills" (fun (l : Dataset.Leader.t) -> List.length l.fills)
       ; Column.timestamp_ns "first_fill" (fill_time ~f:List.hd)
       ; Column.timestamp_ns "last_fill" (fill_time ~f:List.last)
       ; Column.bool "has_state" (fun (l : Dataset.Leader.t) -> Option.is_some l.state)
       ; Column.timestamp_ns "state_time" (fun (l : Dataset.Leader.t) ->
           Option.value_map l.state ~default:Time_ns.epoch ~f:fst)
       ; Column.float "state_account_value" (fun (l : Dataset.Leader.t) ->
           Option.value_map
             l.state
             ~default:0.
             ~f:(fun (_, (s : Clearinghouse_state.t)) ->
               Usd.to_float s.margin_summary.account_value))
       ; Column.int32 "positions" (fun (l : Dataset.Leader.t) ->
           Option.value_map l.state ~default:0 ~f:(fun (_, (s : Clearinghouse_state.t)) ->
             List.length s.positions))
       ])
;;

let fills_schema : (Address.t * User_fill.t) Parquet.Schema.t =
  let f g (_, (fill : User_fill.t)) = g fill in
  Parquet.Schema.create
    [ Column.utf8 "address" (fun (a, _) -> Address.to_string a)
    ; Column.timestamp_ns "time" (f (fun x -> ms_to_time x.time))
    ; Column.utf8 "coin" (f (fun x -> Coin.to_string x.coin))
    ; Column.utf8 "side" (f (fun x -> Side.to_wire x.side))
    ; Column.float "px" (f (fun x -> Price.to_float x.px))
    ; Column.float "sz" (f (fun x -> Size.to_float x.sz))
    ; Column.float "start_position" (f (fun x -> Size.to_float x.start_position))
    ; Column.utf8 "dir" (f (fun x -> x.dir))
    ; Column.float "closed_pnl" (f (fun x -> Usd.to_float x.closed_pnl))
    ; Column.float "fee" (f (fun x -> Usd.to_float x.fee))
    ; Column.utf8 "fee_token" (f (fun x -> Option.value x.fee_token ~default:""))
    ; Column.bool "crossed" (f (fun x -> x.crossed))
    ; Column.int64 "oid" (f (fun x -> Int64.to_int_exn (Order_id.to_int64 x.oid)))
    ; Column.int64 "tid" (f (fun x -> x.tid))
    ; Column.utf8 "hash" (f (fun x -> x.hash))
    ]
;;

let write_leaders path leaders =
  with_tmp path ~f:(fun tmp ->
    Parquet.Writer.with_file ~schema:leaders_schema ~compression:`Zstd tmp ~f:(fun w ->
      Parquet.Writer.add_all w leaders))
;;

let write_fills path leaders =
  with_tmp path ~f:(fun tmp ->
    Parquet.Writer.with_file
      ~schema:fills_schema
      ~compression:`Zstd
      ~row_group_rows:65_536
      tmp
      ~f:(fun w ->
        List.iter leaders ~f:(fun (l : Dataset.Leader.t) ->
          List.iter l.fills ~f:(fun fill -> Parquet.Writer.add w (l.address, fill)))))
;;

let write ~dir (t : Dataset.t) =
  write_leaders (Layout.leaders_parquet dir) t.leaders;
  write_fills (Layout.fills_parquet dir) t.leaders;
  List.sum (module Int) t.leaders ~f:(fun l -> List.length l.fills)
;;
