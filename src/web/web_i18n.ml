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

let default_lang = "en"

let components = Hashtbl.create 2

module type LANG = sig
  val lang : string
  val mo_file : string
end

module Belenios_Gettext (L : LANG) (T : GettextTranslate.TRANSLATE_TYPE) : Web_i18n_sig.GETTEXT = struct
  let lang = L.lang
  open GettextCategory
  open GettextTypes
  let t =
    {
      failsafe = Ignore;
      textdomains = MapTextdomain.empty;
      categories = MapCategory.empty;
      language = Some L.lang;
      codeset = "UTF-8";
      path = [];
      default = "belenios";
    }
  let u = T.create t L.mo_file (fun x -> x)
  let s_ str = T.translate u false str None
  let f_ str = Scanf.format_from_string (T.translate u true (string_of_format str) None) str
  let sn_ str str_plural n = T.translate u false str (Some (str_plural, n))
  let fn_ str str_plural n = Scanf.format_from_string (T.translate u true (string_of_format str) (Some (string_of_format str_plural, n))) str
end

let ( / ) = Filename.concat

let build_gettext_input component lang =
  (module struct
     let lang = lang
     let mo_file = !Web_config.locales_dir / component / (lang ^ ".mo")
   end : LANG)

let default_gettext component =
  let module L = (val build_gettext_input component default_lang) in
  let module G = Belenios_Gettext (L) (GettextTranslate.Dummy) in
  (module G : Web_i18n_sig.GETTEXT)

let () =
  List.iter
    (fun component ->
      let h = Hashtbl.create 10 in
      Hashtbl.add h default_lang (default_gettext component);
      Hashtbl.add components component h
    )
    ["voter"; "admin"]

let lang_mutex = Lwt_mutex.create ()

let get_lang_gettext component lang =
  let langs = Hashtbl.find components component in
  match Hashtbl.find_opt langs lang with
  | Some l -> Lwt.return l
  | None ->
     Lwt_mutex.with_lock lang_mutex
       (fun () ->
         match Hashtbl.find_opt langs lang with
         | Some l -> Lwt.return l
         | None ->
            let module L = (val build_gettext_input component lang) in
            if%lwt Lwt_unix.file_exists L.mo_file then (
              let get () =
                let module L = Belenios_Gettext (L) (GettextTranslate.Map) in
                (module L : Web_i18n_sig.GETTEXT)
              in
              let%lwt l = Lwt_preemptive.detach get () in
              Hashtbl.add langs lang l;
              Lwt.return l
            ) else (
              Lwt.return (Hashtbl.find langs default_lang)
            )
       )

let parse_lang =
  let rex = Pcre.regexp "^([a-z]{2})(?:-.*)?$" in
  fun s ->
  match Pcre.exec ~rex s with
  | groups -> Some (Pcre.get_substring groups 1)
  | exception Not_found -> None

let get_preferred_language () =
  let ri = Eliom_request_info.get_ri () in
  let lazy langs = Ocsigen_request_info.accept_language ri in
  match langs with
  | [] -> default_lang
  | (lang, _) :: _ ->
     match parse_lang lang with
     | None -> default_lang
     | Some lang -> lang

let get_preferred_gettext component =
  let%lwt lang =
    match%lwt Eliom_reference.get Web_state.language with
    | None -> Lwt.return (get_preferred_language ())
    | Some lang -> Lwt.return lang
  in
  get_lang_gettext component lang
