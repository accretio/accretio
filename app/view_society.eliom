(*
 * Accretio is an API, a sandbox and a runtime for social playbooks
 *
 * Copyright (C) 2015 William Le Ferrand
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)


{shared{

open Lwt
open Sessions
open Ys_uid
open Vault

type mode = Public | Private | Sandbox deriving (Json)

type t =
  {
    uid : uid ;
    shortlink : string ;
    supervisor : View_member.t ;
    name : string ;
    description : string ;
    mode : mode ;
    playbook: View_playbook.t ;
    tags : string ;
  }

let uid t = t.uid
let name t = t.name

}}

{server{

let to_view uid =
  lwt supervisor, name, description, mode, playbook, shortlink, tags = $society(uid)->(leader, name, description, mode, playbook, shortlink, tags) in
  let mode =
    match mode with
    | Object_society.Sandbox -> Sandbox
    | Object_society.Public -> Public
    | Object_society.Private -> Private
  in
  lwt supervisor = View_member.to_view supervisor in
  lwt playbook = View_playbook.to_view playbook in
  return {
    uid ;
    shortlink ;
    supervisor ;
    name ;
    description ;
    mode ;
    playbook ;
    tags ;
  }

}}

{client{

open React
open Ys_react
open Eliom_content.Html5
open Eliom_content.Html5.D

let format view =
  let mode =
    match view.mode with
    | Private -> "private"
    | Public -> "public"
    | Sandbox -> "sandbox"
  in
  div ~a:[ a_class [ "view-society" ; mode ] ;
           a_onclick (fun _ -> Service.goto (Service.Society (view.shortlink, view.uid))) ] [
    div ~a:[ a_class [ "name" ]] [ pcdata view.name ] ;
    div ~a:[ a_class [ "description" ]] [ pcdata view.description ] ;
    (* div ~a:[ a_class [ "actions" ]] [
      div ~a:[ a_class [ "view-details" ]] [
        button
          ~a:[ a_button_type `Button ;
               a_onclick (fun _ -> Service.goto (Service.Society (view.shortlink, view.uid))) ]
          [ pcdata "Learn more" ]
      ] ;
    ] *)
  ]

let format_autocomplete view =
  Raw.input ~a:[ a_value view.name ] ()

}}
