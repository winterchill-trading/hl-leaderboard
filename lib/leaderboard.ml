open! Core
open Hl_protocol

module Window = struct
  type t =
    | Day
    | Week
    | Month
    | All_time
  [@@deriving sexp, compare, equal, hash, enumerate]

  let to_string = function
    | Day -> "day"
    | Week -> "week"
    | Month -> "month"
    | All_time -> "allTime"
  ;;

  let of_string = function
    | "day" -> Ok Day
    | "week" -> Ok Week
    | "month" -> Ok Month
    | "allTime" -> Ok All_time
    | s -> Or_error.error_s [%message "unknown leaderboard window" (s : string)]
  ;;
end

module Performance = struct
  type t =
    { pnl : float
    ; roi : float
    ; vlm : float
    }
  [@@deriving sexp, compare, equal]
end

let number_field fields name =
  match List.Assoc.find fields name ~equal:String.equal with
  | Some (`String s) -> Float.of_string s
  | Some (`Float f) -> f
  | Some (`Int i) -> Float.of_int i
  | Some json ->
    raise_s [%message "not a number" (name : string) (Yojson.Safe.to_string json)]
  | None -> raise_s [%message "missing field" (name : string)]
;;

let float_to_json f = `String (Float.to_string_hum ~strip_zero:true ~decimals:10 f)

module Row = struct
  type t =
    { address : Address.t
    ; account_value : float
    ; windows : (Window.t * Performance.t) list
    ; display_name : string option
    }
  [@@deriving sexp, compare, equal]

  let performance t window = List.Assoc.find t.windows window ~equal:Window.equal

  let performance_of_json = function
    | `Assoc fields ->
      { Performance.pnl = number_field fields "pnl"
      ; roi = number_field fields "roi"
      ; vlm = number_field fields "vlm"
      }
    | json -> raise_s [%message "bad performance" (Yojson.Safe.to_string json)]
  ;;

  let window_of_json = function
    | `List [ `String name; perf ] ->
      Window.of_string name |> Or_error.ok_exn, performance_of_json perf
    | json -> raise_s [%message "bad window entry" (Yojson.Safe.to_string json)]
  ;;

  let of_json_exn = function
    | `Assoc fields ->
      let find name = List.Assoc.find fields name ~equal:String.equal in
      let address =
        match find "ethAddress" with
        | Some (`String s) -> Address.of_string s
        | _ -> raise_s [%message "missing ethAddress"]
      in
      let windows =
        match find "windowPerformances" with
        | Some (`List l) -> List.map l ~f:window_of_json
        | None | Some `Null -> []
        | Some _ -> raise_s [%message "bad windowPerformances"]
      in
      let display_name =
        match find "displayName" with
        | Some (`String s) -> Some s
        | _ -> None
      in
      { address
      ; account_value = number_field fields "accountValue"
      ; windows
      ; display_name
      }
    | json -> raise_s [%message "bad leaderboard row" (Yojson.Safe.to_string json)]
  ;;

  let of_json json = Or_error.try_with (fun () -> of_json_exn json)

  let to_json t =
    `Assoc
      [ "ethAddress", `String (Address.to_string t.address)
      ; "accountValue", float_to_json t.account_value
      ; ( "windowPerformances"
        , `List
            (List.map t.windows ~f:(fun (w, (p : Performance.t)) ->
               `List
                 [ `String (Window.to_string w)
                 ; `Assoc
                     [ "pnl", float_to_json p.pnl
                     ; "roi", float_to_json p.roi
                     ; "vlm", float_to_json p.vlm
                     ]
                 ])) )
      ; ( "displayName"
        , match t.display_name with
          | Some s -> `String s
          | None -> `Null )
      ]
  ;;
end

type t = Row.t list [@@deriving sexp_of]

let of_json = function
  | `Assoc fields ->
    (match List.Assoc.find fields "leaderboardRows" ~equal:String.equal with
     | Some (`List rows) ->
       List.mapi rows ~f:(fun i row ->
         Row.of_json row |> Or_error.tag_s ~tag:[%message "leaderboard row" (i : int)])
       |> Or_error.all
     | _ -> Or_error.error_s [%message "missing leaderboardRows"])
  | _ -> Or_error.error_s [%message "leaderboard is not an object"]
;;

let of_string s =
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg -> Or_error.error_s [%message "bad JSON" msg]
;;

let to_json t = `Assoc [ "leaderboardRows", `List (List.map t ~f:Row.to_json) ]

let top ?(min_account_value = 0.) t ~window ~n =
  List.filter_map t ~f:(fun row ->
    match Row.performance row window with
    | Some p when Float.(row.account_value >= min_account_value) -> Some (p.pnl, row)
    | _ -> None)
  |> List.sort ~compare:(fun (pnl1, r1) (pnl2, r2) ->
    match Float.compare pnl2 pnl1 with
    | 0 -> Address.compare r1.Row.address r2.Row.address
    | c -> c)
  |> Fn.flip List.take n
  |> List.map ~f:snd
;;

let candidates ?min_account_value t ~n ~windows =
  let seen = Address.Hash_set.create () in
  List.concat_map windows ~f:(fun window -> top ?min_account_value t ~window ~n)
  |> List.filter ~f:(fun (row : Row.t) ->
    if Hash_set.mem seen row.address
    then false
    else (
      Hash_set.add seen row.address;
      true))
;;
