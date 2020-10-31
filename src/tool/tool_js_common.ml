(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2020 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Js_of_ocaml
open Js_of_ocaml_lwt
open Belenios_platform
open Belenios
open Platform
open Common

let document = Dom_html.document

let ( >>= ) = Js.Opt.bind

let ( >>== ) = Js.Opt.iter

let return_unit =
  Js.some ()

let alert s =
  Dom_html.window##alert (Js.string s)

let prompt s =
  let x = Dom_html.window##prompt (Js.string s) (Js.string "") in
  Js.Opt.to_option (Js.Opt.map x Js.to_string)

let get_textarea_opt id =
  Option.map (fun x -> Js.to_string x##.value)
    (Dom_html.getElementById_coerce id Dom_html.CoerceTo.textarea)

let get_textarea id =
  match get_textarea_opt id with
  | Some x -> x
  | None -> Printf.ksprintf failwith "<textarea> %s is missing" id

let set_textarea id z =
  Option.iter (fun x -> x##.value := Js.string z)
    (Dom_html.getElementById_coerce id Dom_html.CoerceTo.textarea)

let get_input_opt id =
  Option.map (fun x -> Js.to_string x##.value)
    (Dom_html.getElementById_coerce id Dom_html.CoerceTo.input)

let get_input id =
  match get_input_opt id with
  | Some x -> x
  | None -> Printf.ksprintf failwith "<input> %s is missing" id

let set_element_display id x =
  document##getElementById (Js.string id) >>== fun e ->
  e##.style##.display := Js.string x

let set_download id mime fn x =
  let x = (Js.string ("data:" ^ mime ^ ","))##concat (Js.encodeURI (Js.string x)) in
  match Dom_html.getElementById_coerce id Dom_html.CoerceTo.a with
  | None -> ()
  | Some e ->
     e##setAttribute (Js.string "download") (Js.string fn);
     e##.href := x

let get_content x =
  Js.Opt.get (
      document##getElementById (Js.string x) >>= fun e ->
      e##.textContent >>= fun x ->
      Js.some (Js.to_string x)
    ) (fun () -> x)

let set_content id x =
  document##getElementById (Js.string id) >>== fun e ->
  let t = document##createTextNode (Js.string x) in
  Dom.appendChild e t

let clear_content (e : #Dom.node Js.t) =
  while Js.to_bool e##hasChildNodes do
    e##.firstChild >>== fun x ->
    let _ = e##removeChild x in
    ()
  done

let clear_content_by_id id =
  document##getElementById (Js.string id) >>== fun e ->
  clear_content e

let run_handler handler () =
  try handler () with
  | e ->
     let msg = "Unexpected error: " ^ Printexc.to_string e in
     alert msg

let get_params () =
  let x = Js.to_string Dom_html.window##.location##.search in
  let n = String.length x in
  if n < 1 || x.[0] <> '?' then []
  else Url.decode_arguments (String.sub x 1 (n-1))

module LwtJsRandom : Signatures.RANDOM with type 'a t = 'a Lwt.t = struct
  type 'a t = 'a Lwt.t
  let yield = Lwt_js.yield
  let return = Lwt.return
  let bind = Lwt.bind
  let fail = Lwt.fail

  let prng = lazy (pseudo_rng (random_string secure_rng 16))

  let random q =
    let size = Z.bit_length q / 8 + 1 in
    let%lwt () = Lwt_js.yield () in
    let r = random_string (Lazy.force prng) size in
    Lwt.return Z.(of_bits r mod q)
end
