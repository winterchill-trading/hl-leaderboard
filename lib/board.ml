open! Core
open Hl_protocol

module Window = struct
  type t = Leaderboard.Window.t [@@deriving sexp_of]

  let all = Leaderboard.Window.[ Day; Week; Month; All_time ]

  let of_string s =
    match List.find all ~f:(fun w -> String.equal (Leaderboard.Window.to_wire w) s) with
    | Some w -> Ok w
    | None ->
      Or_error.error_s
        [%message "unknown leaderboard window (day, week, month, allTime)" s]
  ;;

  let to_string = Leaderboard.Window.to_wire
  let arg_type = Command.Arg_type.create (fun s -> of_string s |> Or_error.ok_exn)
end

module Row = Leaderboard.Row

type t = Row.t list [@@deriving sexp_of]

let of_string s =
  Or_error.try_with (fun () ->
    (Yojson.Safe.from_string s |> Leaderboard.t_of_yojson).leaderboard_rows)
  |> Or_error.tag ~tag:"leaderboard"
;;

let to_json t = Leaderboard.yojson_of_t { leaderboard_rows = t }

let top ?(min_account_value = 0.) t ~window ~n =
  List.filter_map t ~f:(fun (row : Row.t) ->
    match Row.performance row window with
    | Some p when Float.(row.account_value >= min_account_value) -> Some (p.pnl, row)
    | _ -> None)
  |> List.sort ~compare:(fun (pnl1, (r1 : Row.t)) (pnl2, (r2 : Row.t)) ->
    match Float.compare pnl2 pnl1 with
    | 0 -> Address.compare r1.eth_address r2.eth_address
    | c -> c)
  |> Fn.flip List.take n
  |> List.map ~f:snd
;;

let candidates ?min_account_value t ~n ~windows =
  let seen = Address.Hash_set.create () in
  List.concat_map windows ~f:(fun window -> top ?min_account_value t ~window ~n)
  |> List.filter ~f:(fun (row : Row.t) ->
    match Hash_set.strict_add seen row.eth_address with
    | Ok -> true
    | Duplicate -> false)
;;
