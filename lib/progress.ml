open! Core
open! Async
open Hl_protocol

type t =
  { started : Time_ns.t
  ; candidates : Address.t list
  ; collected : Address.t list
  }
[@@deriving sexp, compare, equal]

let load path =
  match%bind Sys.file_exists_exn path with
  | false -> return (Ok None)
  | true ->
    Monitor.try_with_or_error (fun () -> Reader.load_sexp_exn path t_of_sexp)
    >>| Or_error.map ~f:Option.some
;;

let save path t =
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.save_sexp ~temp_file:(path ^ ".tmp") path (sexp_of_t t)
;;

let pending t =
  let done_ = Address.Set.of_list t.collected in
  List.filter t.candidates ~f:(fun a -> not (Set.mem done_ a))
;;
