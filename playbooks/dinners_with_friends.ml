(*
 * dinners with friends
 *
 * this playbook organizes dinners for a group of friends, asking them for
 * advice and booking restaurants
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

let _ =
  CalendarLib.Time_Zone.change (CalendarLib.Time_Zone.UTC_Plus (-8))


let author = "william@accret.io"
let name = "Dinners with friends"
let description = "This playbook organizes dinners for groups of friends. It asks participants for suggestions, collects opinions and make sure that people agree on a date."
let version = 0
let tags = ""

(* local parameters *)

let key_run_id = "dinner-with-friends-run-id"
let key_previous_run_id = "dinner-with-friends-previous-run-id"
let key_suggestion = sprintf "suggestion-%Ld"
let key_volunteer = sprintf "dinner-with-friends-volunteer-%Ld"
let tag_volunteer = sprintf "volunteer%Ld"
let tag_not_joining = sprintf "notjoining%Ld"
let tag_joining = sprintf "joining%Ld"
let tag_notified = sprintf "notified%Ld"
let key_date = sprintf "dinner-with-friend-date-%Ld"
let key_negative_replies_in_a_row = sprintf "dinner-with-friends-negative-replies-in-a-row-%d"
let tag_timer_volunteer_booking = sprintf "timervolunteerbooking%Ld"
let tag_has_participated = "hasparticipated"
let tag_has_participated_run = sprintf "hasparticipated%Ld"
let key_email_thread_anchor = sprintf "email-thread-anchor-%Ld-%d"
let tag_not_newbie = "notnewbie"
let tag_volunteer_timer = sprintf "volunteer-timer-%Ld"
let key_tagline = "tagline"

(* some helpers ***************************************************************)

let iso_date = "%FT%H:%M:%S"
let get_date context run_id =
  match_lwt context.get ~key:(key_date run_id) with
    None -> return_none
  | Some date ->
    try
      (* "2013-05-15T08:30:00-08:00" *)
      let date = CalendarLib.Printer.Calendar.from_fstring iso_date date in
      return (Some date)
    with _ -> return_none

(* the stages *****************************************************************)

let schedule_dinner context () =
  let run_id = Ys_time.now () in
  lwt _ =
    match_lwt context.get ~key:key_run_id with
      None -> return_unit
    | Some value ->
      context.set ~key:key_previous_run_id ~value
  in
  lwt _ = context.set ~key:key_run_id ~value:(Int64.to_string run_id) in
  lwt participants = context.search_members ~query:"active" () in
  let count_participants = List.length participants in
  match_lwt context.get ~key:"min-participants" with
    None -> context.log_warning "min-participants is missing" ; return `None
  | Some min_participants ->
    context.log_info
      "scheduling dinner, we have %d potential participants, min is %s"
      count_participants
      min_participants ;
    let min_participants = try int_of_string min_participants with _ -> 1 in
    if count_participants < min_participants then
      begin
        context.log_warning "not enough potential participants to set up something" ;
        return `None
      end
    else
      begin
        lwt _ =
          context.message_supervisor
            ~subject:"When is the next dinner?"
            ~data:[ key_run_id, Int64.to_string run_id ]
            ~content:[
              pcdata "Greetings" ; br () ;
              br () ;
              pcdata "There are enough potential participants for another dinner. " ; br () ;
              br () ;
              pcdata "When is the next dinner? Please give me a ISO 8601 date. (eg 2013-05-15T08:30:00)"
            ]
            () in
        return `None
      end

let set_date_and_ask_for_custom_message context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt date = context.get_message_content ~message in

    let is_date_valid =
      try
        let _ = CalendarLib.Printer.Calendar.from_fstring iso_date date in
        true
      with exn -> context.log_error ~exn "couldn't parse date" ; false in

    match is_date_valid with
    | false ->
      return (`AskAgainForDate message)
    | true ->
      lwt _ = context.set ~key:(key_date run_id) ~value:date in
      lwt _ =
        context.reply_to
          ~message
          ~data:[ key_run_id, Int64.to_string run_id ]
          ~content:[
            pcdata "Thanks. What should I tell the next organizer?"
          ]
        ()
      in
      return `None

let ask_again_for_date context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt _ =
      context.reply_to
        ~message
        ~data:[ key_run_id, Int64.to_string run_id ]
        ~content:[
          pcdata "Date format is invalid, please try again"
        ]
        ()
    in
    return `None

let no_volunteer context () =
  context.log_info "no volunteer found" ;
  return `None

let ask_volunteer_for_yelp_link context member =
  match_lwt context.get ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt _ = context.set ~key:(key_volunteer run_id) ~value:(string_of_int member) in
    lwt _ = context.tag_member ~member ~tags:[ tag_volunteer run_id ; tag_joining run_id ] in
    context.log_info "asking %d for a yelp link" member ;
    lwt _ =
      context.message_member
        ~member
        ~subject:"Yelp link?"
        ~content:[
          pcdata "Great, thanks!" ; br () ;
          br () ;
          pcdata "Where could we go? Just sent me a yelp link and I'll forward it to the group!" ; br ()
        ]
        ()
    in
  return `None

let review_yelp_link context message =
  lwt _ = context.forward_to_supervisor ~message ~subject:"Review the yelp link" ~content:[ pcdata "Please review the yelp link" ] () in
  return `None

let forward_yelp_link_to_all_members context message =
  match_lwt context.get ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    match_lwt context.get ~key:(key_volunteer run_id) with
      None -> return `None
    | Some volunteer ->
      lwt content = context.get_message_content ~message in
      lwt _ = context.set ~key:(key_suggestion run_id) ~value:content in
      lwt _ =
        context.set_timer
          ~duration:(Calendar.Period.lmake ~day:2 ~hour:12 ())
          (`NotifyParticipants (run_id, false))
      in
      return (`NotifyParticipants (run_id, false))

let mark_member_as_not_joining context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt member = context.get_message_sender message in
    lwt _ = context.tag_member ~member ~tags:[ tag_not_joining run_id ] in
    lwt negative_replies_in_a_row =
      match_lwt context.get ~key:(key_negative_replies_in_a_row member) with
      | Some counter -> return (int_of_string counter)
      | _ -> return 0
    in
    lwt _ = context.set ~key:(key_negative_replies_in_a_row member) ~value:(string_of_int (negative_replies_in_a_row + 1)) in
    let content =
      if negative_replies_in_a_row < 2 then
        [
          pcdata "Ok, I'll keep you posted about the next dinner!"
        ]
      else
        [
          pcdata "Ok, I'll keep you posted about the next dinner - unless you want to unsubscribe from these emails?"
        ]
    in
    lwt _ =
      context.reply_to
        ~message
        ~content
        ()
    in
    return `None

let remove_member context message =
  lwt member = context.get_message_sender ~message in
  context.log_info "removing member %d" member ;
  lwt _ = context.remove_member ~member in
  lwt _ =
    context.reply_to
      ~message
      ~content:[
        pcdata "Ok, feel free to ping me if you want to come back!"
      ]
      ()
  in
  return `None

let mark_member_as_joining context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt member = context.get_message_sender message in
    lwt _ = context.tag_member ~member ~tags:[ tag_joining run_id ] in
    lwt _ = context.set ~key:(key_negative_replies_in_a_row member) ~value:(string_of_int 0) in
    lwt _ =
      context.reply_to
        ~message
        ~content:[
          pcdata "Great! I'll send you an update once I hear from the others."
        ]
        ()
    in
    return `None

let create_dashboard context () =
  match_lwt context.get ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt participants = context.search_members ~query:(tag_joining run_id) () in
    lwt emails =
      Lwt_list.map_p
        (fun member ->
           lwt email = $member(member)->preferred_email in
           return (li [ pcdata email ]))
      participants
   in
   lwt _ =
     context.message_supervisor
       ~subject:(sprintf "Dasbhoard for run %Ld" run_id)
       ~content:[
         pcdata "Greetings," ; br () ;
         br () ;
         pcdata "Here are the registered participants:" ; br () ;
         br () ;
         ul emails  ;
         br () ;
       ]
       () in
   return `None

let mark_sender_as_volunteer context message =
  lwt member = context.get_message_sender ~message in
  match_lwt context.get ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt _ = context.set ~key:(key_volunteer run_id) ~value:(string_of_int member) in
    lwt _ = context.tag_member ~member ~tags: [ tag_volunteer run_id ; tag_joining run_id ] in
    return (`Message message)

let check_participation context () =
  match_lwt context.get ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    context.log_info "checking participation for run %Ld" run_id ;
    match_lwt context.get ~key:(key_volunteer run_id) with
      None -> return `None
    | Some volunteer ->
      let volunteer = int_of_string volunteer in
      lwt participants = context.search_members ~query:(tag_joining run_id) () in
      match List.filter (fun uid -> uid <> volunteer) participants with
     (*   [] -> return (`NotEnoughParticipants run_id) *)
      | _ -> return (`AskVolunteerToBook run_id)

let not_enough_participants context run_id =
  match_lwt context.get ~key:(key_volunteer run_id) with
    None -> return `None
  | Some volunteer ->
    let member = int_of_string volunteer in
    lwt _ =
      context.message_member
        ~member
        ~subject:"Summary for next week's dinner"
        ~content:[
          pcdata "Greetings," ; br () ;
          br () ;
          pcdata "Unfortunately, it looks like there isn't enough participants this time. Thanks for your suggestion and let's do something later!"
        ]
        ()
    in
    return `None

let ask_volunteer_to_book context run_id =
  context.log_info "checking participation for run %Ld" run_id ;
  match_lwt context.get ~key:(key_volunteer run_id) with
    None -> return `None
  | Some volunteer ->
    match_lwt get_date context run_id with
      None -> return `None
    | Some date ->
      let member = int_of_string volunteer in
      lwt participants = context.search_members ~query:(tag_joining run_id) () in
      let date = CalendarLib.Printer.Calendar.sprint "%c" date in
      lwt _ =
        context.message_member
          ~member
          ~data:[ key_run_id, Int64.to_string run_id ]
          ~subject:"Summary for next week's dinner"
          ~content:[
            pcdata "Greetings," ; br () ;
            br () ;
            pcdata "Great news, there are " ; pcdata (string_of_int (List.length participants)) ; pcdata " participants to next week's dinner!" ; br () ;
            br () ;
            pcdata "Would you mind letting the restaurant know, if you feel that advance booking is needed? " ; pcdata "Dinner's date is " ; pcdata date ; br () ;
            br () ;
            pcdata "Please let me know when I can send the finalized invite to all participants," ; br () ;
            br () ;
            pcdata "Thanks!" ; br ()
          ]
          ()
      in
      lwt _ =
        context.set_timer
          ~label:(tag_timer_volunteer_booking run_id)
          ~duration:(Calendar.Period.lmake ~hour:12 ())
          (`RemindVolunteer (run_id, 0))
      in
      return `None

let remind_volunteer context (run_id, number_of_reminders) =
  context.log_info "remind_volunteer with run_id %Ld, number of reminders %d" run_id number_of_reminders ;
  if number_of_reminders > 2 then
    return (`UnresponsiveVolunteer run_id)
  else
    begin
  context.log_info "need to remind the volunteer about %Ld" run_id ;
  match_lwt context.get ~key:(key_volunteer run_id) with
    None -> return `None
  | Some volunteer ->
    match_lwt get_date context run_id with
      None -> return `None
    | Some date ->

      let member = int_of_string volunteer in
      lwt participants = context.search_members ~query:(tag_joining run_id) () in
      let date = CalendarLib.Printer.Calendar.sprint "%c" date in

      lwt _ =
        context.message_member
          ~member
          ~data:[ key_run_id, Int64.to_string run_id ]
          ~subject:"Summary for next week's dinner"
          ~content:[
            pcdata "Greetings," ; br () ;
            br () ;
            pcdata "Sorry for the reminder but we need to confirm the dinner to all participants so that they can plan accordingly :)" ; br () ;
            br () ;
            pcdata "There are " ; pcdata (string_of_int (List.length participants)) ; pcdata " participants and the dinner's date is " ; pcdata date ;
            pcdata ", do we need a booking or can we tell everyone that we're all set?" ; br () ;
            br () ;
            pcdata "Thanks!" ; br () ;
          ]
          ()
      in
      lwt _ =
        context.set_timer
          ~label:(tag_timer_volunteer_booking run_id)
          ~duration:(Calendar.Period.lmake ~hour:12 ())
          (`RemindVolunteer (run_id, number_of_reminders + 1))
      in
      return `None
    end

let unresponsive_volunteer context run_id =
  lwt _ =
    context.message_supervisor
      ~subject:"Unresponsive volunteer"
      ~data:[ key_run_id, Int64.to_string run_id ]
      ~content:[
        pcdata "Greetings," ; br () ;
        br () ;
        pcdata "Volunteer in run " ; pcdata (Int64.to_string run_id) ; pcdata " hasn't confirmed the dinner. You're needed" ; br () ;
      ]
      ()
  in
  return `None

let make_gcal context volunteer date party_size suggestion =
  try_lwt
    match_lwt Ys_yelp.get_business suggestion with
      None -> return ""
    | Some business ->

      Lwt_log.ign_info_f "found business: %s" (business) ;

      let open Yojson.Basic in
      let open Util in

      let business = from_string business in

      let name = business |> member "name" |> to_string in
      let phone = business |> member "phone" |> to_string in

      let city = business |> member "location" |> member "city" |> to_string in
      let state_code = business |> member "location" |> member "state_code" |> to_string in
      let postal_code = business |> member "location" |> member "postal_code" |> to_string in
      let country_code = business |> member "location" |> member "country_code" |> to_string in

      let addresses = business |> member "location" |> member "address" |> to_list |> filter_string in
      let address = List.hd addresses in

      lwt volunteer_name = $member(volunteer)->name in
      let iso_date = CalendarLib.Printer.Calendar.sprint iso_date date in

      let gcal =
        `Assoc [
          "@context", `String "http://schema.org" ;
          "@type", `String "FoodEstablishmentReservation" ;

          "reservationNumber", `String "012345" ;
          "reservationStatus", `String "http://schema.org/Confirmed" ;

          "underName", `Assoc [
            "@type", `String "Person" ;
            "name", `String volunteer_name ] ;

          "reservationFor", `Assoc [
            "@type", `String "FoodEstablishment" ;
            "name", `String name ;
            "address", `Assoc [
              "@type", `String "PostalAddress" ;
              "streetAddress", `String address ;
              "addressLocality", `String city ;
              "addressRegion", `String state_code ;
              "postalCode", `String postal_code ;
              "addressCountry", `String country_code ;
            ] ;
            "telephone", `String phone ;
          ] ;

          "startTime", `String iso_date ;

          "partySize", `String (string_of_int party_size)
        ]
      in


    let gcal = Yojson.Basic.to_string gcal in
    return ("<script type=\"application/ld+json\">" ^ gcal ^ "</script>")

  with exn -> context.log_error ~exn "couldn't extract the yelp info for the suggestion" ;
    return ""

let confirm_to_all_participants context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    match_lwt get_date context run_id with
      None -> return `None
    | Some date ->
      match_lwt context.get ~key:(key_suggestion run_id) with
        None -> return `None
      | Some suggestion ->

        lwt _ =
          context.cancel_timers
            ~query:(tag_timer_volunteer_booking run_id)
        in

        lwt volunteer = context.get_message_sender message in
        lwt volunteer_name = $member(volunteer)->name in
        lwt participants = context.search_members ~query:(tag_joining run_id) () in
        let participants = List.filter (fun uid -> uid <> volunteer) participants in

        (* This requires google registration ..
           lwt gcal = make_gcal context volunteer date (List.length participants + 1) suggestion in *)

        let date = CalendarLib.Printer.Calendar.sprint "%B %d (it's a %A), around %I:%M %p" date in

        lwt _ =
          Lwt_list.iter_s
            (fun member ->
               lwt message_uid_option =
                 match_lwt context.get ~key:(key_email_thread_anchor run_id member) with
                   Some message ->
                   let message = Ys_uid.of_string message in
                   context.reply_to
                     ~message
                     ~data:[ key_run_id, Int64.to_string run_id ]
                     ~content:[
                       pcdata "Greetings," ; br () ;
                       br () ;
                       pcdata volunteer_name ; pcdata " just confirmed that we're all set for our next dinner." ; br () ;
                       br () ;
                       pcdata "The restaurant is "; Raw.a ~a:[ a_href (uri_of_string (fun () -> suggestion)) ] [ pcdata suggestion ] ; pcdata ", see you there on " ; pcdata date ; pcdata "!" ; br () ;
                     ]
                     ()
                 | None ->
                   context.message_member
                     ~member
                     ~data:[ key_run_id, Int64.to_string run_id ]
                     ~subject:"Dinner confirmation"
                     ~content:[
                       pcdata "Greetings," ; br () ;
                       br () ;
                       pcdata volunteer_name ; pcdata " just confirmed that we're all set for our next dinner." ; br () ;
                       br () ;
                       pcdata "The restaurant is "; Raw.a ~a:[ a_href (uri_of_string (fun () -> suggestion)) ] [ pcdata suggestion ] ; pcdata ", see you there on " ; pcdata date ; pcdata "!" ; br () ;
                     ]
                     () in
               match message_uid_option with
                 None -> return_unit
               | Some uid ->
                 Lwt_log.ign_info_f "message sent to member %d, message id is %d" member uid ;
                 lwt _ = context.set ~key:(key_email_thread_anchor run_id member) ~value:(Ys_uid.to_string uid) in
                 return_unit)
            participants
        in

        lwt _ =
          context.reply_to
            ~message
            ~content:[ pcdata "Thanks, see you there!" ]
            ()
        in


        return `None

(* in case we need to notify the participants to a dinner *)

let make_announcement_current_run context () =
  match_lwt context.get ~key:(key_run_id) with
    None ->
    context.log_info "no run id found, notifying nobody" ;
    return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    return (`MakeAnnouncementRunId run_id)

let make_announcement_run_id context run_id =
  lwt _ =
    context.message_supervisor
      ~data:[ key_run_id, Int64.to_string run_id ]
      ~subject:"Please type your announcement"
      ~content:[
        pcdata "Greetings" ; br () ;
        br () ;
        pcdata "Please reply with your announcement above"
      ]
      ()
  in
  return `None

let prepare_announcement context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt announcement = context.get_message_content ~message in
    match_lwt context.search_members ~query:(tag_joining run_id) () with
      [] ->
      lwt _ =
        context.reply_to
          ~message
          ~content:[ pcdata "Sorry but there are no participants for the run id you sent me" ]
          ()
      in
      return `None
    | _ as participants ->
      lwt _ =
        context.reply_to
          ~message
          ~content:[
            pcdata "Ok, I'm sending the following message to " ;
            pcdata (string_of_int (List.length participants)) ;
            pcdata " participants:" ; br () ;
            br () ;
            i [ pcdata announcement ] ; br () ;
            br ()
          ]
          ()
      in
      return (`MakeAnnouncement (announcement, participants))


let debrief_current_run context () =
  match_lwt context.get ~key:(key_run_id) with
    None ->
    context.log_info "no run id found, can't debrief anything" ;
    return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    return (`DebriefRunId run_id)

let debrief context run_id =
  match_lwt context.search_members ~query:(tag_joining run_id) () with
    [] ->
    context.log_info "there were no participants for run %Ld" run_id ;
    return `None
  | _ as participants ->
    lwt participants =
      Lwt_list.map_s
        (fun member ->
           lwt preferred_email, name = $member(member)->(preferred_email, name) in
           return (li [ pcdata name ; pcdata " " ; pcdata preferred_email ]))
        participants
in

    lwt _ =
      (* TODO: ask the volunteer instead of the supervisor? *)
      context.message_supervisor
        ~data:[ key_run_id, Int64.to_string run_id ]
        ~subject:"Debriefing of the Dinner"
        ~content:[
          pcdata "Greetings," ; br () ;
          br () ;
          pcdata "Please edit the following list of participants, leaving only those who came and haven't paid yet. Please attach the receipt and print the total cost to be splitted among participants at the top of the message" ; br () ;
          br () ;
          ul participants ;
        ]
        ()
    in

    return `None

let split_payment context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    match_lwt get_date context run_id with
      None -> return `None
    | Some date ->

      lwt content = context.get_message_content ~message in
      let members = Ys_email.get_all_emails content in
      context.log_info "splitting payments between %d members" (List.length members) ;
      lwt members =
        Lwt_list.fold_left_s
          (fun acc email ->
             match_lwt Object_member.Store.find_by_email email with
             | None -> return acc
             | Some uid ->
               return (UidSet.add uid acc))
          UidSet.empty
          members
      in
      let members = UidSet.elements members in
      lwt _ =
        Lwt_list.iter_s
          (fun member -> context.tag_member ~member ~tags:[ tag_has_participated ; tag_has_participated_run run_id ])
          members
      in
      let amount = ref 0.0 in
      (try
         Scanf.sscanf content "$%f" (fun f -> amount := f);
       with _ -> ()) ;
      if !amount = 0.0 then
        begin
          lwt _ =
            context.forward_to_supervisor
              ~message
              ~subject:"Couldn't parse amount"
              ~data:[ key_run_id, Int64.to_string run_id ]
              ~content:[ pcdata "Couldn't grab amount :/" ]
              ()
          in
          return `None
        end
      else
        begin
          let owed = ceil (!amount *. 100. /. (float_of_int (List.length members))) /. 100.0 in
          let date = CalendarLib.Printer.Calendar.sprint "%B %d" date in
          let label = context.society_name ^ " / " ^ date in
          let calls = List.map (fun member -> `RequestPayment (member, label, owed, message)) members in
          (* we don't have a way to return a set of calls, but we can cheat & use timers for that *)
          lwt _ =
            Lwt_list.iter_s
              (fun call ->
                 context.set_timer ~duration:(Calendar.Period.lmake ~minute:1 ()) call)
              calls
          in

          lwt _ = context.set_timer ~duration:(Calendar.Period.lmake ~minute:1 ()) (`CheckMembers message) in
          return (`ThankOrganizer run_id)
end


let check_members context message =
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None -> return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    lwt members =  extract_members_from_message context message in
    (* let's compute who didn't came *)
    lwt registered_participants = context.search_members ~query:(tag_joining run_id) () in
    let registered_participants = Ys_uid.of_list registered_participants in
    let didnt_came = UidSet.diff registered_participants (UidSet.of_list members) in

    lwt didnt_came =
      Lwt_list.map_s
        (fun member ->
           lwt preferred_email, name = $member(member)->(preferred_email, name) in
           return (li [ pcdata name ; pcdata " " ; pcdata preferred_email ]))
        (UidSet.elements didnt_came)
    in

    lwt _ =
      context.reply_to
        ~message
        ~data:[ key_run_id, Int64.to_string run_id ]
        ~content:[
          pcdata "The people below registered but didn't came. Reply with the list of the people that you would like to remove from the group" ;
          br () ;
          ul didnt_came ;
        ]
        ()
  in
  return `None

let thank_organizer context run_id =
  match_lwt context.get ~key:(key_volunteer run_id) with
    None -> return `None
  | Some member ->
    let member = Ys_uid.of_string member in
    lwt _ =
      context.message_member
        ~member
        ~subject:"Thanks!"
        ~content:[ pcdata "Thank you very much for organizing this dinner!" ]
        ()
    in
    return `None

let remove_members context message =
  lwt members = extract_members_from_message context message in
  lwt _ =
    Lwt_list.iter_s
      (fun member ->
         context.log_info "removing member %d" member ;
         context.remove_member ~member)
      members
  in
  lwt _ =
    context.reply_to
      ~message
      ~content:[ pcdata "Ok, I removed " ;
                 pcdata (string_of_int (List.length members)) ;
                 pcdata " members" ]
      ()
  in
  return `None

let notify_participants context (run_id, only_new_members) =
  context.log_info "reminding all participants for run_id %Ld" run_id ;
  lwt participants = context.search_members ~query:(sprintf "active -%s -%s" (tag_joining run_id) (tag_not_joining run_id)) () in
  context.log_info "found %d participants to contact" (List.length participants) ;
  List.iter
    (fun member ->
       Lwt_log.ign_info_f "member is %d" member)
    participants ;
  match_lwt context.get ~key:(key_suggestion run_id) with
    None -> return `None
  | Some content ->
    match_lwt context.get ~key:(key_volunteer run_id) with
      None -> return `None
    | Some volunteer ->
      let volunteer = Ys_uid.of_string volunteer in
      match_lwt get_date context run_id with
        None -> return `None
      | Some date ->
        lwt volunteer_name = $member(volunteer)->name in
        let date = CalendarLib.Printer.Calendar.sprint "%B %d (it's a %A), around %I:%M %p" date in
        lwt _ =
          Lwt_list.iter_s
            (fun member ->
               lwt message_uid_option =
                 match_lwt context.get ~key:(key_email_thread_anchor run_id member) with
                   Some message when not only_new_members ->
                   let message = Ys_uid.of_string message in
                   context.reply_to
                     ~message
                     ~data:[ key_run_id, Int64.to_string run_id ]
                     ~content:[
                       pcdata "Greetings," ; br () ;
                       br () ;
                       pcdata "I'm wrapping up the headcount for the next dinner, on " ; pcdata date ; pcdata "." ; br () ;
                       br () ;
                       pcdata "Would you like to join us?" ; br () ;
                     ]
                     ()
                 | None ->
                   begin
                     match_lwt context.check_tag_member ~member ~tag:tag_not_newbie with
                     false ->
                     lwt _ = context.tag_member ~member ~tags:[ tag_not_newbie] in
                     context.message_member
                       ~member
                       ~data:[ key_run_id, Int64.to_string run_id ]
                       ~subject:("You have been invited to the " ^ context.society_name ^ " group")
                       ~content:[
                         pcdata "Greetings," ; br () ;
                         br () ;
                         pcdata "I hope you are having a great week! " ; br () ;
                         br () ;
                         span [ pcdata context.society_description ] ; br () ;
                         br () ;
                         pcdata "This week, " ; pcdata volunteer_name ; pcdata " made a great suggestion for the next dinner: " ; br () ;
                         br () ;
                         Raw.a ~a:[ a_href (uri_of_string (fun () -> content)) ] [ pcdata content ] ; br () ;
                         br () ;
                         pcdata "We would meet on " ; pcdata date ; br () ;
                         br () ;
                         pcdata "Would you like to join us?" ; br () ;
                       ]
                       ()
                   | true when not only_new_members ->
                     lwt _ = context.tag_member ~member ~tags:[ tag_notified run_id ] in
                     context.message_member
                       ~member
                       ~data:[ key_run_id, Int64.to_string run_id ]
                       ~subject:("New event in the " ^ context.society_name ^ " group")
                       ~content:[
                         pcdata "Greetings," ; br () ;
                         br () ;
                         pcdata "I hope you are having a great week! " ; br () ;
                         br () ;
                         pcdata volunteer_name ; pcdata " has a great suggestion for the next dinner: " ; br () ;
                         br () ;
                         Raw.a ~a:[ a_href (uri_of_string (fun () -> content)) ] [ pcdata content ] ; br () ;
                         br () ;
                         pcdata "We would meet on " ; pcdata date ; br () ;
                         br () ;
                         pcdata "Are you in?" ; br () ;
                       ]
                       ()
                   | _ -> return_none
                   end
                 | _ -> return_none
               in
               match message_uid_option with
                 None -> return_unit
               | Some uid ->
                 Lwt_log.ign_info_f "message sent to member %d, message id is %d" member uid ;
                 lwt _ = context.set ~key:(key_email_thread_anchor run_id member) ~value:(Ys_uid.to_string uid) in
                 return_unit)
            participants
        in
        lwt _ =
          if not only_new_members then
            context.message_member
              ~member:volunteer
              ~subject:"Quick update"
              ~content:[
                pcdata "Greetings," ; br () ;
                br () ;
                pcdata "Quick update about the dinner: I just sent a reminder to the members of the group, we'll be able to wrap up a list of participants very soon." ; br ();
                br () ;
                pcdata "Thanks for organizing that one!" ; br ()
              ]
              ()
          else
            return_none
        in
        return `None

let notify_participants_current_run context () =
   match_lwt context.get ~key:(key_run_id) with
    None ->
    context.log_info "no run id found, can't notify participants" ;
    return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    return (`RunId (run_id, false))

let notify_participants_current_run_only_new_members context () =
   match_lwt context.get ~key:(key_run_id) with
    None ->
    context.log_info "no run id found, can't notify participants" ;
    return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    return (`RunId (run_id, true))

let reset_anchors_current_run context () =
  match_lwt context.get ~key:(key_run_id) with
    None ->
    context.log_info "no run id found, can't reset anchors" ;
    return `None
  | Some run_id ->
    let run_id = Int64.of_string run_id in
    context.log_info "resetting email anchors for run %Ld" run_id ;
    lwt participants = context.search_members ~query:(sprintf "active -%s -%s" (tag_joining run_id) (tag_not_joining run_id)) () in
    lwt _ =
      Lwt_list.iter_p
      (fun member ->
        context.delete ~key:(key_email_thread_anchor run_id member))
      participants in
    return `None

let extract_tagline context message =
  lwt content = context.get_message_content ~message in
  match_lwt context.get_message_data ~message ~key:key_run_id with
    None ->
    context.log_info "couldn't extract run_id from message metadata" ;
    return (`FindVolunteer content)
  | Some run_id ->
    let run_id = Int64.of_string run_id in

    lwt potential_candidates =
      match_lwt context.get ~key:key_previous_run_id with
        None -> return []
      | Some previous_run_id ->
      let previous_run_id = Int64.of_string previous_run_id in
      context.search_members ~query:(tag_has_participated_run previous_run_id) ()
    in
    lwt _ =
      context.set_timer
        ~label:(tag_volunteer_timer run_id)
        ~duration:(Calendar.Period.lmake ~hour:24 ())
        (`FindVolunteer content)
    in
    match potential_candidates with
      [] ->
      let _ =
        context.reply_to
          ~message
          ~data:[ key_run_id, Int64.to_string run_id ; key_tagline, content ]
          ~content:[
            pcdata "Do you have a specific member in mind to ask for a suggestion? If you don't send me a suggestion within 24 hours, I'll make a random choice"
          ]
          ()
      in
      return `None
    | _ as members ->
       lwt members =
          Lwt_list.map_s
            (fun member ->
               lwt preferred_email, name = $member(member)->(preferred_email, name) in
               return (li [ pcdata name ; pcdata " " ; pcdata preferred_email ]))
            members
        in
        lwt _ =
          context.reply_to
            ~message
            ~data:[ key_run_id, Int64.to_string run_id ; key_tagline, content ]
            ~content:[
              pcdata "Do you want to pick up a member below? If you don't send me a volunteer within 24 hours, I'll make a random choice" ;
              br () ;
              ul members ;
            ]
            ()
        in
        return `None

let extract_candidate context message =
  match_lwt context.get_message_data ~message ~key:key_tagline with
    None ->
    lwt _ =
      context.reply_to
        ~message
        ~content:[ pcdata "Can't find the attached tagline" ]
        ()
    in
    return `None
  | Some tagline ->
    lwt _ =
      match_lwt context.get_message_data ~message ~key:key_run_id with
        None -> return_unit
      | Some run_id ->
        let run_id = Int64.of_string run_id in
        lwt _ = context.cancel_timers ~query:(tag_volunteer_timer run_id) in
        return_unit in
    lwt members = extract_members_from_message context message in
    match members with
      [] -> return (`FindVolunteer tagline)
    | member :: _ ->
      lwt _ = context.add_member ~member in
      return (`FindVolunteerWithHint (tagline, member))



(* the playbook ***************************************************************)

PARAMETERS
   - "Minimum number of participants", "min-participants"
   - "Maximum number of participants", "max-participants"

PLAYBOOK

   #import core_join_request
   #import core_announcements
   #import core_payments
   #import core_invite
   #import find_volunteer

   *make_announcement_current_run ~> `MakeAnnouncementRunId of int64 ~> make_announcement_run_id<forward> ~> `Message of email ~> prepare_announcement ~> `MakeAnnouncement of (string * int list) ~> make_announcement

                                                     set_date_and_ask_for_custom_message ~> `AskAgainForDate of int ~> ask_again_for_date<forward> ~> `Message of email ~> set_date_and_ask_for_custom_message

   extract_tagline<forward> ~> `Message of email ~> extract_candidate ~> `FindVolunteerWithHint of (string * int) ~> find_volunteer_with_tagline_and_hint
                                                    extract_candidate ~> `FindVolunteer of string ~> find_volunteer_with_tagline
   *schedule_dinner<forward> ~> `Message of email ~> set_date_and_ask_for_custom_message<forward> ~> `Message of email ~> extract_tagline ~> `FindVolunteer of string ~> find_volunteer_with_tagline
                                                     look_for_candidate ~> `NoVolunteer ~> no_volunteer
                                                     return_volunteer ~> `Volunteer of int ~> ask_volunteer_for_yelp_link<forward> ~> `Message of email ~> review_yelp_link<forward> ~> `Message of email ~> forward_yelp_link_to_all_members ~> `NotifyParticipants of (int64 * bool) ~> notify_participants

       candidate_with_message ~> `Message of int ~> mark_sender_as_volunteer ~> `Message of int ~> review_yelp_link

       notify_participants ~> `NotJoining of email ~> mark_member_as_not_joining ~> `RemoveMember of email ~> remove_member
       notify_participants ~> `Joining of email ~> mark_member_as_joining

       *check_participation ~> `NotEnoughParticipants of int64 ~> not_enough_participants
        check_participation ~> `AskVolunteerToBook of int64 ~> ask_volunteer_to_book ~>  `Booked of email ~> confirm_to_all_participants
                                                               ask_volunteer_to_book ~> `RemindVolunteer of int64 * int ~> remind_volunteer ~> `RemindVolunteer of int64 * int ~> remind_volunteer
                                                                                                                           remind_volunteer ~> `UnresponsiveVolunteer of int64 ~> unresponsive_volunteer
                                                                                                                           remind_volunteer ~> `Booked of email ~> confirm_to_all_participants

       *debrief_current_run ~> `DebriefRunId of int64 ~> debrief<forward> ~> `Message of email ~> split_payment ~> `Message of email ~> split_payment
        split_payment ~> `ThankOrganizer of int64 ~> thank_organizer
        split_payment ~> `RequestPayment of (int * string * float * int) ~> request_payment
        split_payment ~> `CheckMembers of int ~> check_members ~> `Message of email ~> remove_members

 *notify_participants_current_run ~> `RunId of (int64 * bool) ~> notify_participants
 *notify_participants_current_run_only_new_members ~> `RunId of (int64 * bool) ~> notify_participants

 *create_dashboard
 *reset_anchors_current_run

(* the cron part isn't easy as we want to make it dependent from the parameter above *)


CRON remind_all "14 8 * * 2 *"


PROPERTIES
  - "Duties", "Participants take turns at picking up a restaurant. Once the number of participants has been determined by accretio, they are also responsible for making the reservation."
