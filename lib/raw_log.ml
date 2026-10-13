open! Core
open! Async

let format_ts time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
  let p = Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday) in
  sprintf "%sT%02d:%02d:%02d.%03d%03dZ" (Date.to_string date) p.hr p.min p.sec p.ms p.us
;;

let one_line body =
  if String.mem body '\n' || String.mem body '\r'
  then
    String.map body ~f:(function
      | '\n' | '\r' -> ' '
      | c -> c)
  else body
;;

let line ~recv_ts body = String.concat [ format_ts recv_ts; " "; one_line body; "\n" ]

let append path ~recv_ts body =
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.with_file ~append:true path ~f:(fun w ->
    Writer.write w (line ~recv_ts body);
    return ())
;;

module Entry = struct
  type t =
    { recv_ts : Time_ns.t
    ; body : string
    }
  [@@deriving sexp_of]
end

let read path =
  match%bind Sys.file_exists_exn path with
  | false -> return (Ok [])
  | true ->
    let%map text = Reader.file_contents path in
    let lines = String.split text ~on:'\n' in
    (* After the split, the element after the last newline is "" for a complete file and
       the partial line otherwise; drop it either way. *)
    let lines = List.drop_last lines |> Option.value ~default:[] in
    List.filter_map lines ~f:(fun l ->
      match Market_data.Raw_minute.Line.parse l with
      | Ok (Frame { recv_ts; payload }) -> Some (Ok { Entry.recv_ts; body = payload })
      | Ok Disconnect -> None
      | Error e -> Some (Error (Error.tag_s e ~tag:[%message path])))
    |> Or_error.all
;;
