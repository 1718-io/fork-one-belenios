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
open Belenios_platform
open Belenios
open Belenios_tool_common
open Belenios_tool_js_common
open Serializable_j
open Tool_js_common
open Tool_tkeygen
open Tool_js_i18n.Gettext

let tkeygen _ =
  let module P : PARAMS = struct
    let group = get_textarea "group"
  end in
  let module X = (val make (module P : PARAMS) : S) in
  let open X in
  let {id=_; priv; pub} = trustee_keygen () in
  let hash =
    let pub = trustee_public_key_of_string Yojson.Safe.read_json pub in
    Platform.sha256_b64 (Yojson.Safe.to_string pub.trustee_public_key)
  in
  set_textarea "pk" pub;
  set_content "public_key_fp" hash;
  set_download "private_key" "application/json" "private_key.json" priv;
  set_element_display "submit_form" "inline";
  Js._false

let fill_interactivity () =
  document##getElementById (Js.string "interactivity") >>== fun e ->
  let b = Dom_html.createButton document in
  let t = document##createTextNode (Js.string (s_ "Generate a key")) in
  b##.onclick := Dom_html.handler tkeygen;
  Dom.appendChild b t;
  Dom.appendChild e b

let () =
  Lwt.async (fun () ->
      let%lwt _ = Js_of_ocaml_lwt.Lwt_js_events.onload () in
      let belenios_lang = Js.to_string (Js.Unsafe.pure_js_expr "belenios_lang") in
      let%lwt () = Tool_js_i18n.init "admin" belenios_lang in
      fill_interactivity ();
      Lwt.return_unit
    )
