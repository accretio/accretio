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

type interlocutor = Stage of string | Member of View_member.t | CatchAll

type action = Pending | RoutedToStage of string
type t =
  {
    uid : uid ;
    created_on : int64 ;
    origin : interlocutor ;
    destination : interlocutor ;
    reference : string ;
    subject : string ;
    content : string ;
    action : action ;
  }

}}

{server{

let to_interlocutor = function
  Object_message.Stage stage -> return (Stage stage)
| Object_message.Member uid -> lwt view = View_member.to_view uid in return (Member view)
| Object_message.CatchAll -> return CatchAll

let to_view uid =
  lwt created_on, origin, destination, reference, subject, content, action = $message(uid)->(created_on, origin, destination, reference, subject, content, action) in
  lwt origin = to_interlocutor origin in
  lwt destination = to_interlocutor destination in
  let action =
    match action with
      Object_message.Pending -> Pending
    | Object_message.RoutedToStage stage -> RoutedToStage stage in
  return
    {
      created_on ;
      uid ;
      origin ;
      destination ;
      reference ;
      subject ;
      content ;
      action ;
    }
}}

{client{

open React
open Ys_react
open Eliom_content.Html5
open Eliom_content.Html5.D

let format_interlocutor = function
    | Stage stage -> [ pcdata "From stage " ; pcdata stage ]
    | Member member -> [ pcdata "From member " ; View_member.format member ]
    | CatchAll -> [ pcdata "CatchAll" ]

let format view =
  div ~a:[ a_class [ "message" ]] [
    Ys_timeago.format ~a:[ a_class [ "message-created-on" ]] view.created_on ;
    div ~a:[ a_class [ "message-reference" ]] [
      pcdata view.reference
    ] ;
    div ~a:[ a_class [ "message-origin" ]] (format_interlocutor view.origin) ;
    div ~a:[ a_class [ "message-destination" ]] (format_interlocutor view.destination) ;
    div ~a:[ a_class [ "message-subject" ]] [ pcdata "Subject: " ;  pcdata view.subject ] ;
    div ~a:[ a_class [ "message-content" ]] [
      pcdata view.content ;
    ]
  ]

}}
