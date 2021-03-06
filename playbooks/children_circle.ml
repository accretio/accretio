open Lwt

open Printf
open CalendarLib

open Api

open Eliom_content.Html5
open Eliom_content.Html5.D

open Message_parsers

let author = "william@accret.io"
let name = "Children circle"
let description = "Weekly children activities"

let version = 0
let tags = ""

(* some utilities *************************************************************)

let current_week () =
   let now = Calendar.now () in
   Calendar.year now * 53 + Calendar.week now

(* stages *********************************************************************)

let solicit_weekly_organizer context member =
  lwt _ =
    context.message_member
      ~member
      ~subject:"Would you like to suggest a children activity for this weekend?"
      ~content:[
        pcdata "Hello" ; br () ;
        br () ;
        pcdata "Are you available for a simple children activity this weekend?" ; br () ;
        br () ;
      ]
      ()
  in
  return (`CandidateWasNotified member)

let mark_as_not_joining_and_ask_someone_else context message =
  let week = current_week () in
  lwt member = context.get_message_sender ~message in
  lwt _ = context.cancel_timers ~query:(sprintf "waiting%05d%d" week member) in
  lwt _ = context.tag_member ~member ~tags:[ sprintf "declined%d" week ] in
  lwt _ = context.untag_member ~member ~tags:[ sprintf "accepted%d" week ] in
  return `AskSomeoneElse

let mark_as_joining_but_ask_someone_else context message =
  let week = current_week () in
  lwt member = context.get_message_sender ~message in
  lwt _ = context.cancel_timers ~query:(sprintf "waiting%05d%d" week member) in
  lwt _ = context.tag_member ~member ~tags:[ sprintf "declined%d" week ] in
  lwt _ = context.untag_member ~member ~tags:[ sprintf "accepted%d" week ] in
  return `AskSomeoneElse

let mark_as_joining_and_forward_suggestion context message =
  let week = current_week () in
  lwt member = context.get_message_sender ~message in
  lwt _ = context.cancel_timers ~query:(sprintf "waiting%05d%d" week member) in
  lwt _ = context.set ~key:(sprintf "organizer%d" week) ~value:(string_of_int member) in
  lwt _ = context.tag_member ~member ~tags:[ sprintf "declined%d" week ] in
  lwt _ = context.untag_member ~member ~tags:[ sprintf "accepted%d" week ] in
  lwt suggestion = context.get_message_content ~message in
  lwt _ =
    context.message_supervisor
      ~subject:"Please format the suggestion for the other members"
      ~content:[
        pcdata suggestion
      ]
      () in
  return `None

let forward_suggestion_to_all_members context message =
  let week = current_week () in
  lwt suggestion = context.get_message_content ~message in
  lwt _ = context.set ~key:(sprintf "suggestion%d" week) ~value:suggestion in
  lwt members = context.search_members ~query:(sprintf "active -declined%d -accepted%d" week week) () in
  match_lwt context.get ~key:(sprintf "organizer%d" week) with
    None -> return `None
  | Some organizer ->
    lwt _ =
      Lwt_list.iter_p
        (fun member ->
           lwt _ =
             context.message_member
               ~member
               ~subject:"Want to do something with the kids this weekend?"
               ~content:[
                 pcdata "Hi," ; br () ;
                 br () ;
                 pcdata organizer ; pcdata "suggests that we " ; pcdata suggestion ; br () ;
                 br () ;
                 pcdata "Would you like to join?" ; br () ;
               ]
               () in return_unit)
        members
    in
    return `None

let mark_as_joining context message =
  let week = current_week () in
  lwt member = context.get_message_sender ~message in
  lwt _ = context.set ~key:(sprintf "organizer%d" week) ~value:(string_of_int member) in
  lwt _ = context.tag_member ~member ~tags:[ sprintf "accepted%d" week ] in
  lwt _ = context.untag_member ~member ~tags:[ sprintf "declined%d" week ] in
  return `None

let mark_as_not_joining context message =
  let week = current_week () in
  lwt member = context.get_message_sender ~message in
  lwt _ = context.set ~key:(sprintf "organizer%d" week) ~value:(string_of_int member) in
  lwt _ = context.tag_member ~member ~tags:[ sprintf "declined%d" week ] in
  lwt _ = context.untag_member ~member ~tags:[ sprintf "accepted%d" week ] in
  return `None

let confirm_event context message =
  let week = current_week () in
  lwt members = context.search_members ~query:(sprintf "accepted%d" week) () in
  match_lwt context.get ~key:(sprintf "suggestion%d" week) with
  | None ->
    context.log_error "couldn't find the suggestion for week %d, although we have %d participants" week (List.length members) ;
    return `None
  | Some suggestion ->
    lwt _ =
      Lwt_list.iter_p
        (fun member ->
           lwt _ =
             context.message_member
               ~member
               ~subject:"This weekend's children activity"
               ~content:[
                 pcdata "Hi," ; br () ;
                 br () ;
                 pcdata "Looks like we'll be " ; pcdata (string_of_int (List.length members)) ; pcdata " this week at " ; br () ;
                 br () ;
                 pcdata suggestion ; br () ;
                 br () ;
                 pcdata "Looking forward to it!" ; br () ;
               ]
               ()
           in return_unit)
        members
    in
    return `None

(* the playbook ***************************************************************)


PLAYBOOK

  #import demo
  #import weekly_activity

  pickup_weekly_organizer ~> `Candidate of int ~> solicit_weekly_organizer ~> `CandidateWasNotified of int ~> candidate_was_notified
                                                  solicit_weekly_organizer ~> `CandidateAccepted of email ~> candidate_accepted
                                                  solicit_weekly_organizer ~> `CandidateDeclined of email ~> candidate_declined



(*
  pickup_weekly_organizer ~> `NotJoining of email ~> mark_as_not_joining_and_ask_someone_else ~> `AskSomeoneElse ~> pickup_weekly_organizer
  pickup_weekly_organizer ~> `JoiningButNotOrganizing of email ~> mark_as_joining_but_ask_someone_else ~> `AskSomeoneElse ~> pickup_weekly_organizer
  pickup_weekly_organizer ~> `JoiningAndOrganizing of email ~> mark_as_joining_and_forward_suggestion<forward> ~> `Message of email ~> forward_suggestion_to_all_members

      forward_suggestion_to_all_members ~> `Joining of email ~> mark_as_joining ~> `Check ~> pick_up_a_restaurant
      forward_suggestion_to_all_members ~> `NotJoining of email ~> mark_as_not_joining
*)

*confirm_event

(* trigger the playbook each wednesday ****************************************)

CRON pickup_weekly_organizer "0 0 * * 3 *"
