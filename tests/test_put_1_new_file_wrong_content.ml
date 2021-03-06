#!/usr/bin/env ocaml

#use "test.ml"

let request = {|
PUT /objects/73bcc5e2fdb23b560e112be22c901379bf9ce3a1f9ca32acd92bc6ba5667a0ae HTTP/1.1
Host: localhost
Content-Length: 7170

(*
 * ERRORight (c) 2015 Stanislav Artemkin <artemkin@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
*)

open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

let is_sha256_hex_digest str =
  if String.length str <> 64 then false
  else String.for_all str ~f:Char.is_alphanum

module Json = struct
  let error msg =
    let msg = `Assoc [ "message", `String msg ] in
    Yojson.pretty_to_string msg

  let metadata ~oid ~size ~self_url ~download_url =
    let msg = `Assoc [
        "oid", `String oid;
        "size", `Intlit (Int64.to_string size);
        "_links", `Assoc [
          "self", `Assoc [ "href", `String (Uri.to_string self_url) ];
          "download", `Assoc [ "href", `String (Uri.to_string download_url) ]
        ]
      ] in
    Yojson.pretty_to_string msg

  let download url =
    let msg = `Assoc [
        "_links", `Assoc [
          "download", `Assoc [ "href", `String (Uri.to_string url) ]
        ]
      ] in
    Yojson.pretty_to_string msg

  let upload url =
    let url = Uri.to_string url in
    let msg = `Assoc [
        "_links", `Assoc [
          "upload", `Assoc [ "href", `String url ];
          "verify", `Assoc [ "href", `String url ]
        ]
      ] in
    Yojson.pretty_to_string msg

  let parse_oid_size str =
    try_with (fun () -> return @@ Yojson.Safe.from_string str) >>= function
    | Error _ -> return None
    | Ok (`Assoc ["oid", `String oid; "size", `Int size]) ->
      if is_sha256_hex_digest oid then
        return (Some (oid, Int64.of_int size))
      else return None
    | Ok (`Assoc ["oid", `String oid; "size", `Intlit size]) ->
      let oid = if is_sha256_hex_digest oid then Some oid else None in
      let size = Option.try_with (fun () -> Int64.of_string size) in
      return @@ Option.both oid size
    | Ok _ -> return None

end

let add_content_type headers content_type =
  Header.add headers "content-type" content_type

let respond_with_string ~meth ~code str =
  let headers = add_content_type (Header.init ()) "application/vnd.git-lfs+json" in
  let body = match meth with `GET | `POST -> `String str | `HEAD -> `Empty in
  Server.respond ~headers ~body code

let respond_error ~meth ~code msg =
  respond_with_string ~meth ~code @@ Json.error msg

let get_oid_path ~oid =
  let oid02 = String.prefix oid 2 in
  let oid24 = String.sub oid ~pos:2 ~len:2 in
  Filename.of_parts [oid02; oid24; oid]

let get_object_filename ~root ~oid =
  Filename.of_parts [root; "/objects"; get_oid_path ~oid]

let check_object_file_stat ~root ~oid =
  let path = get_object_filename ~root ~oid in
  try_with (fun () -> Unix.stat path)

let get_download_url uri oid =
  Uri.with_path uri @@ Filename.concat "/data/objects" oid

let respond_object_metadata ~root ~meth ~uri ~oid =
  check_object_file_stat ~root ~oid >>= function
  | Error _ -> respond_error ~meth ~code:`Not_found "Object not found"
  | Ok stat ->
    let download_url = get_download_url uri oid in
    respond_with_string ~meth ~code:`OK
    @@ Json.metadata ~oid ~size:(Unix.Stats.size stat) ~self_url:uri ~download_url

let respond_object ~root ~meth ~oid =
  let filename = get_object_filename ~root ~oid in
  try_with ~run:`Now
    (fun () ->
       Reader.open_file filename
       >>= fun rd ->
       let headers = add_content_type (Header.init ()) "application/octet-stream" in
       match meth with
       | `GET ->
         Server.respond ~headers ~body:(`Pipe (Reader.pipe rd)) `OK
       | `HEAD ->
         Reader.close rd >>= fun () ->
         Server.respond ~headers ~body:`Empty `OK)
  >>= function
  | Ok res -> return res
  | Error _ -> respond_error ~meth ~code:`Not_found "Object not found"

let oid_from_path path =
  match String.rsplit2 path ~on:'/' with
  | Some ("/objects", oid) ->
    if is_sha256_hex_digest oid then `Metadata oid else `Empty
  | Some ("/data/objects", oid) ->
    if is_sha256_hex_digest oid then `Object oid else `Empty
  | _ -> `Empty

(* TODO fix this *)
let fix_uri port uri =
  let uri = Uri.with_scheme uri (Some "http") in
  Uri.with_port uri (if port = 80 then None else Some port)

let handle_get root meth uri =
  let path = Uri.path uri in
  match oid_from_path path with
  | `Metadata oid -> respond_object_metadata ~root ~meth ~uri ~oid
  | `Object oid -> respond_object ~root ~meth ~oid
  | `Empty -> respond_error ~meth ~code:`Not_found "Wrong path"

let handle_post root meth uri body =
  let path = Uri.path uri in
  if path <> "/objects" then
    respond_error ~meth ~code:`Not_found "Wrong path"
  else
    Body.to_string body >>= fun body ->
    Json.parse_oid_size body >>= function
    | None -> respond_error ~meth ~code:`Bad_request "Invalid body"
    | Some (oid, size) ->
      check_object_file_stat ~root ~oid >>= function
      | Ok stat when (Unix.Stats.size stat = size) ->
        let url = get_download_url uri oid in
        respond_with_string ~meth ~code:`OK @@ Json.download url
      | Ok _ ->
        respond_error ~meth ~code:`Bad_request "Wrong object size"
      | Error _ ->
        let url = Uri.with_path uri @@ Filename.concat "/upload/objects" oid in
        respond_with_string ~meth ~code:`Accepted @@ Json.upload url

let serve_client ~root ~port ~body _sock req =
  let uri = Request.uri req in
  if Option.is_none (Uri.host uri) then
    respond_with_string ~meth:`GET
      ~code:`Bad_request @@ Json.error "Wrong host"
  else
    let uri = fix_uri port uri in
    match Request.meth req with
    | (`GET as meth) | (`HEAD as meth) -> handle_get root meth uri
    | (`POST as meth) -> handle_post root meth uri body
    | _ -> Server.respond `Method_not_allowed

let start_server ~root ~host ~port () =
  eprintf "Listening for HTTP on port %d\n" port;
  Unix.Inet_addr.of_string_or_getbyname host
  >>= fun host ->
  let listen_on = Tcp.Where_to_listen.create
      ~socket_type:Socket.Type.tcp
      ~address:(`Inet (host, port))
      ~listening_on:(fun _ -> port)
  in
  Server.create
    ~on_handler_error:`Raise
    listen_on
    (serve_client ~root ~port)
  >>= fun _ -> Deferred.never ()

let () =
  Command.async_basic
    ~summary:"Start a Git LFS server"
    Command.Spec.(
      empty
      +> anon (maybe_with_default "./.lfs" ("root" %: string))
      +> flag "-s" (optional_with_default "127.0.0.1" string) ~doc:"address IP address to listen on"
      +> flag "-p" (optional_with_default 8080 int) ~doc:"port TCP port to listen on"
    )
    (fun root host port -> start_server ~root ~host ~port)
  |> Command.run

|}

let response = {|
HTTP/1.1 400 Bad Request
connection: keep-alive
content-length: 125
content-type: application/vnd.git-lfs+json

{
  "message":
    "Content doesn't match SHA-256 digest: 73bcc5e2fdb23b560e112be22c901379bf9ce3a1f9ca32acd92bc6ba5667a0ae"
}
|}

let () =
  Test.netcat request response

