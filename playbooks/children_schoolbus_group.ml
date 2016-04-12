(*
 * children_schoolbus
 *
 * this playbook organizes field trips for a group of children
 *
 *
 * william@accret.io
 *
 *)


open Lwt

open Printf
open CalendarLib

open Api

open Eliom_content.Html5
open Eliom_content.Html5.D

open Message_parsers
open Toolbox

open Ys_uid

open Children_schoolbus_types

let author = "william@accret.io"
let name = "Children schoolbus group"
let description = "this playbook organizes field trips for a group of children"
let version = 0
let tags = ""

(* initially let's do pickups at playgrounds *)

(* some keys ******************************************************************)

let key_pickup_point = "pickup-point"

(* some tags ******************************************************************)

let tag_asked = "asked"
let tag_confirmed = "confirmed" (* <- people that have accepted the pickup spot *)


(* the stages *****************************************************************)

(******************************************************************************)
(* Setting up the group                                                       *)
(******************************************************************************)

let init__ context () =
  context.log_info "calling init for the society" ;
  lwt _ =
    context.message_supervisor
      ~subject:"Welcome"
      ~content:[
        pcdata "Greetings," ; br () ;
        br () ;
        pcdata "This society just got created. What will be the pickup point for the group?" ; br () ;
      ]
      ()
  in
  return `None

let extract_pickup_point context message =
  match_lwt context.get ~key:key_pickup_point with
    Some _ ->
    lwt _ =
      context.reply_to
        ~message
        ~content:[ pcdata "Sorry the pickup point can only be updated from the control panel" ]
        ()
    in
    return `None
  | None ->
    lwt content = context.get_message_content ~message in
    lwt _ = context.set ~key:key_pickup_point ~value:content in
    lwt _ =
      context.reply_to
        ~message
        ~content:[
          pcdata "Thanks, I registered the following pickup point:" ; br () ;
          br () ;
          i [ pcdata content ] ; br () ;
          br ()
        ]
        ()
    in
    return `None

let new_member__ context member =
  context.log_info "we have a new member, %d" member ;
  match_lwt context.get ~key:key_pickup_point with
    None ->
    return `None
  | Some pickup_point ->
    match_lwt context.check_tag_member ~member ~tag:tag_asked with
      true -> return `None
    | false ->
      lwt salutations = salutations member in
      lwt _ =
        context.message_member
          ~member
          ~remind_after:(Calendar.Period.lmake ~hour:36 ())
          ~subject:"Preschool on wheels - quick question"
          ~content:[
            salutations ; br () ;
            br () ;
            pcdata "I'm making progress on a proposal for a first trip. No date yet, but the destination would very likely be the SF Zoo. I am working on getting firm quotes from various charter companies." ; br () ;
            br () ;
            pcdata "To make things easier for them what would you think of doing the pickup from " ; pcdata pickup_point ; pcdata " sometime around 8:30am? We could go doorstep to doorstep later." ; br () ;
          ]
          ()
      in
      lwt _ = context.tag_member ~member ~tags:[ tag_asked ] in
      return `None


(* the playbook ***************************************************************)

PLAYBOOK

#import core_remind

*init__<forward> ~> `Message of email ~> extract_pickup_point
new_member__


PROPERTIES
  - "Your duties", "None"