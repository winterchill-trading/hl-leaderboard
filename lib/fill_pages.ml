open! Core
open! Async
open Hl_protocol

let page_limit = 2000
let key (f : User_fill.t) = f.tid, Int64.to_int_exn (Order_id.to_int64 f.oid)

type next =
  | Done
  | Next of int
[@@deriving sexp_of]

let next ~start_time ~page ~fresh =
  if List.length page < page_limit
  then Done
  else (
    let newest =
      List.fold page ~init:start_time ~f:(fun acc (f : User_fill.t) -> Int.max acc f.time)
    in
    if fresh = 0 || newest <= start_time
    then Next (Int.max newest start_time + 1)
    else Next newest)
;;

type result =
  { fills : User_fill.t list
  ; pages : int
  ; complete : bool
  ; next_start : int
  }
[@@deriving sexp_of]

module Key = struct
  type t = int * int [@@deriving sexp, compare, hash]
end

let walk ?max_pages ?(seen = []) ~start_time ~fetch ~on_page () =
  let keys = Hashtbl.create (module Key) in
  List.iter seen ~f:(fun f -> Hashtbl.set keys ~key:(key f) ~data:());
  let acc = Queue.create () in
  let rec go ~start_time ~pages =
    match max_pages with
    | Some max when pages >= max ->
      return (Ok { fills = []; pages; complete = false; next_start = start_time })
    | _ ->
      (match%bind fetch ~start_time with
       | Error _ as e -> return e
       | Ok (raw, page) ->
         let%bind () = on_page raw page in
         let fresh =
           List.filter page ~f:(fun f ->
             match Hashtbl.add keys ~key:(key f) ~data:() with
             | `Ok -> true
             | `Duplicate -> false)
         in
         Queue.enqueue_all acc fresh;
         let pages = pages + 1 in
         (match next ~start_time ~page ~fresh:(List.length fresh) with
          | Done ->
            let newest =
              List.fold page ~init:start_time ~f:(fun a (f : User_fill.t) ->
                Int.max a f.time)
            in
            return (Ok { fills = []; pages; complete = true; next_start = newest })
          | Next start_time -> go ~start_time ~pages))
  in
  let%map.Deferred.Or_error result = go ~start_time ~pages:0 in
  let fills =
    Queue.to_list acc
    |> List.stable_sort ~compare:(fun (a : User_fill.t) b ->
      Comparable.lexicographic
        [ (fun (a : User_fill.t) b -> Int.compare a.time b.time)
        ; (fun a b -> Int.compare a.tid b.tid)
        ]
        a
        b)
  in
  { result with fills }
;;
