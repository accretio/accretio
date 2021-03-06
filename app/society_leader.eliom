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
open Ys_uid
open Vault
open View_society

type bundle =
  {
    uid : uid ;
    view : View_society.t ;
    (* playbook info *)
    automata : string ;
    triggers : (([ `Unit | `Int | `Int64 | `Float | `String | `Raw ]) * string) list ;
    mailables : string list ;
    email_actions : (string * string list) list ;
    (* society info *)
    members : (View_member.t * string list) list ;
    data : (string * string) list ;
    societies : View_society.t list ;
  }

}}

{server{

open Eliom_content.Html5
open Eliom_content.Html5.D

open Vault

let retrieve_members uid =
  lwt members = $society(uid)->members in
  Lwt_list.fold_left_s
    (fun acc -> function
         | `Member tags, uid ->
           lwt view = View_member.to_view uid in
           return ((view, tags) :: acc)
         | _ -> return acc)
      []
      members

let retrieve uid =
  lwt view = View_society.to_view uid in
  lwt members = retrieve_members uid in
  lwt data, playbook, societies = $society(uid)->(data, playbook, societies) in
  Lwt_log.ign_info_f "society %d relies on playbook %d" uid playbook ;
  let automata, triggers, mailables, email_actions =
    let playbook = Registry.get playbook in
    let module P = (val playbook : Api.PLAYBOOK) in
    P.automata, P.triggers, P.mailables, P.email_actions
  in
  let triggers = List.fast_sort (fun (_, s1) (_, s2) -> String.compare s1 s2) triggers in
  lwt societies = Lwt_list.map_s (fun (_, uid) -> View_society.to_view uid) societies in
  return
    {
      uid ;
      view ;
      automata ;
      triggers ;
      mailables ;
      email_actions ;
      members ;
      data ;
      societies ;
    }

let update_mode (uid, mode) =
  protected_connected
    (fun session ->
       Lwt_log.ign_info_f "updating mode for society %d" uid ;
       (* only the leader can change the status for now *)
       lwt leader = $society(uid)->leader in
       match session.member_uid = leader with
        | false -> return_none
        | true ->
          let mode' =
            match mode with
              Sandbox -> Object_society.Sandbox
            | Public -> Object_society.Public
            | Private -> Object_society.Private in
          lwt _ = $society(uid)<-mode = mode' in
          return (Some mode))

let update_mode = server_function ~name:"society-leader-update-mode" Json.t<int * mode> update_mode

(* logs  *)

let get_logs (society, since) =
  let since = max since (Int64.sub (Ys_time.now ()) 86400L) in
  Lwt_log.ign_info_f "retrieving logs for society %d, since %Ld" society since ;
  Logs.list_all_from_society society since

let get_logs = server_function ~name:"society-leader-get-logs" Json.t<int * int64> get_logs

(* history & stack *)

let get_stack society =
  $society(society)->stack

let get_stack = server_function ~name:"society-leader-get-stack" Json.t<int> get_stack

let reset_stack society =
  Lwt_log.ign_info_f "resetting stack for society %d" society ;
  lwt stack = $society(society)<-stack %%% (fun _ -> return []) in
  Lwt_log.ign_info_f "stack reset for society %d" society ;
  return (Some stack)

let reset_stack = server_function ~name:"society-leader-reset-stack" Json.t<int> reset_stack

let remove_from_stack (society, created_on, stage, args) =
  lwt stack = $society(society)<-stack %%% (fun stack ->
      return (List.filter (fun call -> not (call.Ys_executor.created_on = created_on && call.Ys_executor.stage = stage && call.Ys_executor.args = args)) stack)
    ) in
  return (Some stack)

let remove_from_stack = server_function ~name:"society-leader-remove-from-stack" Json.t<int * int64 * string * string> remove_from_stack

let force (society, created_on, stage, args) =
  lwt stack = $society(society)<-stack %%% (fun stack ->
      return
        (List.map
           (function call ->
             if call.Ys_executor.created_on = created_on && call.Ys_executor.stage = stage && call.Ys_executor.args = args then
               Ys_executor.({ call with schedule = Immediate })
             else
               call
           ) stack)
    ) in
  ignore_result (Executor.step society) ;
  return (Some stack)

let force = server_function ~name:"society-leader-force" Json.t<int * int64 * string * string> force

(* triggers, todo ACL *)

let trigger_unit (society, stage) =
  Lwt_log.ign_info_f "triggering stage unit, society is %d, stage is %s" society stage ;
  Executor.stack_and_trigger_unit society stage

let trigger_int (society, stage, (args: int)) =
  Lwt_log.ign_info_f "triggering stage int, society is %d, stage is %s, args is %d" society stage args ;
  Executor.stack_and_trigger_int society stage args

let trigger_float (society, stage, (args: float)) =
  Lwt_log.ign_info_f "triggering stage float, society is %d, stage is %s, args is %f" society stage args ;
  Executor.stack_and_trigger_float society stage args

let trigger_string (society, stage, (args: string)) =
  Lwt_log.ign_info_f "triggering stage string, society is %d, stage is %s, args is %s" society stage args ;
  Executor.stack_and_trigger_string society stage args

let trigger_raw (society, stage, (args: string)) =
  (* convert from json to value?? *)
  Lwt_log.ign_info_f "triggering stage raw, society is %d, stage is %s, args is %s" society stage args ;
  Executor.stack_and_trigger_raw society stage args

let trigger_unit = server_function ~name:"society-leader-trigger-unit" Json.t<int * string> trigger_unit
let trigger_int = server_function ~name:"society-leader-trigger-int" Json.t<int * string * int> trigger_int
let trigger_float = server_function ~name:"society-leader-trigger-float" Json.t<int * string * float> trigger_float
let trigger_string = server_function ~name:"society-leader-trigger-string" Json.t<int * string * string> trigger_string
let trigger_raw = server_function ~name:"society-leader-trigger-raw" Json.t<int * string * string> trigger_raw

(* members *)

let add_members (uid, emails, tags) =
  protected_connected
    (fun _ ->
       Lwt_log.ign_info_f "adding members to society %d, emails are %s" uid emails ;
       let emails = Ys_email.get_all_emails emails in
       lwt _ =
         Lwt_list.iter_p
           (fun email ->
              lwt member =
                match_lwt Object_member.Store.find_by_email email with
                | Some uid -> return uid
                | None ->
                  match_lwt Object_member.Store.create
                              ~preferred_email:email
                              ~emails:[ email ]
                              () with
                  | `Object_already_exists (_, uid) -> return uid
                  | `Object_created member -> return member.Object_member.uid
              in
              Lwt_log.ign_info_f "adding member %d via email %s in society %d" member email uid ;
              let tags = "active" :: tags in

              lwt _ = $society(uid)<-members +=! (`Member tags, member) in
              (* we need to call add_member here *)
              lwt _ = Executor.stack_int uid Api.Stages.new_member member in
              return_unit)
           emails in
       lwt members = retrieve_members uid in
       return (Some members))

let add_members = server_function ~name:"society-leader-add-members" Json.t<int * string * string list> add_members

let remove_member (uid, member) =
  protected_connected
    (fun _ ->
       lwt _ = $society(uid)<-members -= member in
       lwt members = retrieve_members uid in
       return (Some members))

let remove_member = server_function ~name:"society-leader-remove-member" Json.t<int * int> remove_member

let update_member_tags (uid, member, tags) =
  let tags = "active" :: (List.filter (fun s -> s <> "active") tags) in
  protected_connected
    (fun _ ->
       lwt _ = $society(uid)<-members -= member in
       lwt _ = $society(uid)<-members += (`Member tags, member) in
       lwt members = retrieve_members uid in
       return (Some members))

let update_member_tags = server_function ~name:"society-leader-update-member-tags" Json.t<int * int * string list> update_member_tags

(* mailbox *)

let get_messages_inbox (society, since) =
  Lwt_log.ign_debug_f "get_messages_inbox for society %d since %Ld" society since ;
  lwt inbox = $society(society)->inbox in
  let inbox = List.filter (fun (`Message slip, _) -> slip.Object_society.received_on > since) inbox in
  let inbox = List.rev inbox in
  lwt messages = Lwt_list.map_p (fun (`Message slip, uid) -> lwt view = View_message.to_view uid in return (slip.Object_society.received_on, view)) inbox in
  Lwt_log.ign_debug_f "got %d inbox messages" (List.length messages) ;
  return messages

let get_messages_inbox = server_function ~name:"society-leader-get-messages-inbox" Json.t<int * int64> get_messages_inbox

let get_messages_outbox (society, since) =
  Lwt_log.ign_debug_f "get_messages_outbox for society %d since %Ld" society since ;
  lwt outbox = $society(society)->outbox in
  let outbox = List.filter (fun (`Message slip, _) -> slip.Object_society.received_on > since) outbox in
  let outbox = List.rev outbox in
  lwt messages = Lwt_list.map_p (fun (`Message slip, uid) -> lwt view = View_message.to_view uid in return (slip.Object_society.received_on, view)) outbox in
  Lwt_log.ign_debug_f "got %d outbox messages" (List.length messages) ;
  return messages

let get_messages_outbox = server_function ~name:"society-leader-get-messages-outbox" Json.t<int * int64> get_messages_outbox

let reply_message (society, message, content) =
  protected_connected
    (fun _ ->
       Lwt_log.ign_info_f "replying to message %d with content %s" message content ;
       match_lwt $message(message)->destination with
        | Object_message.Society (society, stage) ->
          begin
            lwt context_factory = Executor.context_factory society in
            let module Factory = (val context_factory : Api.STAGE_CONTEXT_FACTORY) in
            let module Specifics : Api.STAGE_SPECIFICS =
              struct
                type outbound = unit
                let outbound_dispatcher _ _ = Obj.magic ()
                let stage = stage
              end
            in
            let module Context = Factory(Specifics) in
            let context = Context.context in
            context.Api.reply_to
              ~message
              ~content:[ pcdata content ]
              ()
          end
        | Object_message.Member member as origin ->
          (match_lwt $message(message)->origin with
           | Object_message.Society (society, stage) as destination ->
             lwt (reference, subject) = $message(message)->(reference, subject) in
             lwt uid =
               match_lwt Object_message.Store.create
                           ~origin
                           ~content
                           ~raw:content
                           ~subject:((* "Re: " ^ *) subject)
                           ~destination
                           ~references:[ reference ]
                           ~reference:(Object_message.create_reference content)
                           () with
               | `Object_already_exists (_, uid) -> return uid
               | `Object_created message -> return message.Object_message.uid in
             lwt _ = $society(society)<-inbox += (`Message (Object_society.{ received_on = Ys_time.now () ; read = false }), uid) in
             lwt playbook = $society(society)->playbook in
             let module Playbook = (val (Registry.get playbook) : Api.PLAYBOOK) in
             lwt _ = Executor.cancel_reminders society uid in
             (match_lwt Playbook.dispatch_message_automatically uid stage with
              | None -> return (Some uid)
              | Some call ->
                lwt _ = $message(uid)<-action = Object_message.RoutedToStage call.Ys_executor.stage in
                lwt _ = $society(society)<-stack %% (fun stack -> call :: stack) in
                return (Some uid))
           | _ -> return_none)
        | _ ->
          return_none)

let reply_message = server_function ~name:"society-leader-reply-message" Json.t<int * int * string> reply_message

(* TODO: deprecate this method when moving to the manage interface *)
let create_message_and_trigger_stage (society, sender, content, stage) =
  Lwt_log.ign_info_f "creating message for society %d, sender is %d, content is %s, stage is %s" society sender content stage ;
  return_none

let create_message_and_trigger_stage = server_function ~name:"create-message-and-trigger-stage" Json.t<int * int * string * string> create_message_and_trigger_stage

(* store *)

let set_value (society, key, value_option) =
  protected_connected
    (fun _ ->
       lwt _ = $society(society)<-data %%
                                    (fun data ->
                                       match value_option with
                                         None -> List.remove_assoc key data
                                       | Some v -> (key, v) :: List.remove_assoc key data) in
       lwt data = $society(society)->data in
       return (Some data))

let set_value = server_function ~name:"society-leader-set-value" Json.t<int * string * string option> set_value

(* tick the recipe manually *)

let tick society =
  protected_connected
    (fun _ ->
       ignore_result (Executor.step society) ;
       return (Some ()))

let tick = server_function ~name:"society-leader-tick" Json.t<int> tick


(* dispatch message *)

let dispatch_message_manually (message, destination) =
  Lwt_log.ign_info_f "dispatch_message_manually message %d to destination %s" message destination ;
  protected_connected
    (fun _ ->
       match_lwt $message(message)->destination with
        | Object_message.Stage _ -> return_none
        | Object_message.Member _ -> return_none
        | Object_message.CatchAll -> return_none
        | Object_message.Society (society, stage) ->
          lwt playbook = $society(society)->playbook in
          let module Playbook = (val (Registry.get playbook) : Api.PLAYBOOK) in
          match Playbook.dispatch_message_manually message stage destination with
            None ->
            Lwt_log.ign_info_f "couldn't create a call for message %d, from stage %s to destination %s" message stage destination ;
            return_none
          | Some call ->
            lwt _ = $message(message)<-action = Object_message.RoutedToStage call.Ys_executor.stage in
            lwt _ = Executor.push_and_execute society call in
            let action = View_message.RoutedToStage call.Ys_executor.stage in
            return (Some action))

let dispatch_message_manually = server_function ~name:"society-leader-dispatch-message" Json.t<int * string> dispatch_message_manually

(* settings *)

let update_description (society, description) =
  protected_connected
    (fun _ ->
       lwt _ = $society(society)<-description %% (fun _ -> description) in
       return (Some ()))

let update_description = server_function ~name:"society-leader-update-description" Json.t<int * string> update_description

let update_name (society, name) =
  protected_connected
    (fun _ ->
       lwt _ = $society(society)<-name %% (fun _ -> name) in
       return (Some ()))

let update_name = server_function ~name:"society-leader-update-name" Json.t<int * string> update_name

let update_supervisor (society, email) =
  Lwt_log.ign_info_f "update supervisor request in society %d, new supervisor is %s" society email ;
  protected_connected
    (fun _ ->
       match_lwt Object_member.Store.find_by_email email with
         None -> return_none
       | Some uid ->
         lwt _ = $society(society)<-leader = uid in
         lwt _ = $member(uid)<-societies +=! (`Society, society) in
         lwt view = View_member.to_view uid in
         return (Some view))

let update_supervisor = server_function ~name:"society-leader-update-supervisor" Json.t<int * string> update_supervisor

let add_society (society, playbook, name, description) : View_society.t option Lwt.t =
  Lwt_log.ign_info_f "creating new children society in society %d, playbook %d, name %s, description %s" society playbook name description ;
  protected_connected
    (fun session ->
       (* TODO: clean that up *)
       match_lwt Object_society.Store.search_name name with
       | child :: _ ->
         (* relink with that *)
         lwt _ = $society(society)<-societies +=! (`Society name, child) in
         lwt view = View_society.to_view child in
         return (Some view)
       | [] ->
         (* TODO: add some safeguards here around duplicates in societies *)
         match_lwt Ys_shortlink.create () with
           None ->
           Lwt_log.ign_error_f "couldn't create shortlink" ;
           return_none
         | Some shortlink ->
           match_lwt Object_society.Store.create
                       ~shortlink
                       ~leader:session.member_uid
                       ~name
                       ~description
                       ~playbook
                       ~mode:Object_society.Public
                       ~data:[]
                       () with
           | `Object_already_exists (_, uid) ->
             (* TODO: fishy *)
               return_none
             | `Object_created obj ->
               let child = obj.Object_society.uid in
               lwt _ = $society(society)<-societies += (`Society name, child) in
               lwt _ = $member(session.member_uid)<-societies += (`Society, child) in
               lwt _ = Executor.stack_unit child Api.Stages.init () in
               lwt view = View_society.to_view child in
               return (Some view))

let add_society = server_function ~name:"society-leader-add-society" Json.t<int * int * string * string> add_society

let link_society (society1, society2) =
  Lwt_log.ign_info_f "linking society %d as a children of society %d" society2 society1 ;
  protected_connected
    (fun session ->
       lwt name = $society(society2)->name in
       lwt _ = $society(society1)<-societies +=! (`Society name, society2) in
       lwt _ = $member(session.member_uid)<-societies +=! (`Society, society2) in
       lwt view = View_society.to_view society2 in
       return (Some view))

let link_society = server_function ~name:"society-leader-link-society" Json.t<int * int> link_society

}}

{client{

open React
open Ys_react
open Eliom_content.Html5
open Eliom_content.Html5.D
open View_society

let refresh_rate = 1.0

let attach society container fetcher viewer =
  let rec fetch since =
    let container = To_dom.of_div container in
    lwt data = fetcher (society, since) in

    let since =
      List.fold_left
        (fun _ (timestamp, data) ->
           Dom.insertBefore container (To_dom.of_div (viewer data)) (container##firstChild) ;
           timestamp)
        since
        data
    in
    lwt _ = Lwt_js.sleep refresh_rate in
    fetch since
  in
  ignore_result
    (lwt _ = Lwt_js.yield () in fetch 0L)

let attach_logs society logs =
  attach society logs (%get_logs) (fun (msg, ts, source) -> div ~a:[ a_class [ "log" ; source ]] [ Ys_timeago.format ts ; pcdata ": " ; pcdata msg ])

let attach_stack society holder =
  let rec fetch () =
    lwt stack = %get_stack society in
    RList.update holder stack ;
    lwt _ = Lwt_js.sleep refresh_rate in
    fetch ()
  in
  ignore_result
    (lwt _ = Lwt_js.yield () in fetch ())

let attach_outbox society outbox =
 let format message =
    let textarea_reply = Raw.textarea (pcdata "") in
    let reply _ =
      match Ys_dom.get_value_textarea textarea_reply with
        "" -> Help.warning "Please say something"
      | _ as reply ->
        Authentication.if_connected
          (fun _ -> rpc %reply_message (society, message.View_message.uid, reply) (fun _ -> Ys_dom.set_value_textarea textarea_reply ""))
    in
    let reply =
      button

        ~a:[ a_onclick reply ]
        [ pcdata "Reply" ]
    in
    div ~a:[ a_class [ "message-box" ]] [
      View_message.format message ;
      textarea_reply ;
      reply ;
    ]

  in
  attach society outbox (%get_messages_outbox) format

let dom bundle =

  let attach_inbox society inbox =
    let format message =
      let action, update_action = S.create message.View_message.action in
      let tagger =
        match message.View_message.destination with
          View_message.Member _
        | View_message.CatchAll -> pcdata ""
        | View_message.Society (_, stage)
        | View_message.Stage stage ->
          try
            let options = List.assoc stage bundle.email_actions in
          div ~a:[ a_class [ "tagger" ]]
            (List.map
               (fun option ->
                  button
                    ~a:[ a_button_type `Button ;
                         a_onclick (fun _ -> detach_rpc %dispatch_message_manually (message.View_message.uid, option) update_action) ]
                    [ pcdata option ])
               options)
        with Not_found -> pcdata ""
      in
      let classs =
        R.a_class
          (S.map
             (function
               | View_message.Pending -> [ "message-box" ; "message-pending" ]
               | View_message.RoutedToStage _ -> [ "message-box" ])
             action)
      in
      let action =
        R.node
          (S.map
             (function
               | View_message.Pending ->
                 div ~a:[ a_class [ "message-action" ]] [
                   pcdata "pending action"
                 ]
               | View_message.RoutedToStage stage ->
                 div ~a:[ a_class [ "message-action" ]] [
                   pcdata "routed to stage " ;
                   pcdata stage
                 ])
             action)
      in
      let textarea_reply = Raw.textarea (pcdata "") in
      let reply _ =
        match Ys_dom.get_value_textarea textarea_reply with
          "" -> Help.warning "Please say something"
        | _ as reply ->
          Authentication.if_connected
            (fun _ -> rpc %reply_message (society, message.View_message.uid, reply) (fun _ -> Ys_dom.set_value_textarea textarea_reply ""))
      in
      let reply =
        button
          ~a:[ a_button_type `Button ; a_onclick reply ]
          [ pcdata "Reply" ]
      in
      div ~a:[ classs ] [
        View_message.format message ;
        action ;
        tagger ;
        div ~a:[ a_class [ "message-reply" ]] [
          textarea_reply ;
          reply ;
        ]
      ]
    in
    attach society inbox (%get_messages_inbox) format
  in

  let view = bundle.view in

  (* toggling the mode should have an impact on the scheduler *)

  let mode =
    let mode, update_mode = S.create view.mode in
    let update_mode mode =
      Authentication.if_connected
        (fun _ -> rpc %update_mode (view.uid, mode) update_mode)
    in
    let mode_toggle m l =
      button

        ~a:[ a_onclick (fun _ -> update_mode m) ;
             R.a_class (S.map (function mode -> if mode = m then [ "active" ] else []) mode) ]
        [ pcdata l ]
    in
    div ~a:[ a_class [ "society-leader-mode" ]] [
      mode_toggle Sandbox "Sandbox" ;
      mode_toggle Public "Public" ;
      mode_toggle Private "Private" ;
    ]
  in

  (* displaying the logs more or less in RT *)

  let logs = div ~a:[ a_class [ "logs-inner" ]] [] in

  attach_logs view.uid logs ;

  (* displaying the mailbox more or less in RT *)

  let inbox = div ~a:[ a_class [ "inbox" ]] [] in

  let outbox = div ~a:[ a_class [ "outbox" ]] [] in

  attach_inbox view.uid inbox ;
  attach_outbox view.uid outbox ;

  (* the stack *)

  let stack = RList.create () in
  attach_stack view.uid stack ;

  let format_call call =
    let force _ =
      Authentication.if_connected
        (fun _ -> rpc %force (view.uid, call.Ys_executor.created_on, call.Ys_executor.stage, call.Ys_executor.args) (RList.update stack))
    in
    let force =
      button

        ~a:[ a_onclick force ]
        [ pcdata "Force" ]
    in
    let remove _ =
      Authentication.if_connected
        (fun _ -> rpc %remove_from_stack (view.uid, call.Ys_executor.created_on, call.Ys_executor.stage, call.Ys_executor.args) (RList.update stack))
    in
    let remove =
      button

        ~a:[ a_onclick remove ]
        [ pcdata "Cancel" ]
    in
    div ~a:[ a_class [ "call" ]] [
      pcdata call.Ys_executor.stage ;
      force ;
      remove ;
    ]
  in

  let tick =
    let tick _ =
      Authentication.if_connected
        (fun _ -> rpc %tick view.uid (fun () -> ()))
    in
    let tick =
      button

        ~a:[ a_onclick tick ]
        [ pcdata "Tick" ]
    in
    let reset _ =
      Authentication.if_connected
        (fun _ -> rpc %reset_stack view.uid (RList.update stack))
    in
    let reset =
      button

        ~a:[ a_onclick reset ]
        [ pcdata "Reset" ]
    in
    div ~a:[ a_class [ "stack-control" ]] [
      tick ; reset ;
    ]
  in

  let stack = RList.map_in_div_hd ~a:[ a_class [ "stack" ]] tick format_call stack in

  (* the graph *)

  let graph = div ~a:[ a_class [ "playbook-automata" ; "left" ]] [] in
  Ys_viz.render graph bundle.automata ;

  (* the triggers *)

  let triggers =
    List.map
      (function (ctyp, stage) ->
        match ctyp with
        | `Unit ->
          let call =
            button
              ~a:[ a_button_type `Button ; a_onclick (fun _ -> ignore_result (%trigger_unit (view.uid, stage))) ]
              [ pcdata stage ]
          in
          div ~a:[ a_class [ "trigger" ]] [ call ]
        | `Int ->
          let input = input ~a:[ a_input_type `Number ] () in
          let call _ =
            let arg = Ys_dom.get_value input in
            ignore_result (%trigger_int (view.uid, stage, int_of_string arg))
          in
          let call =
            button
              ~a:[ a_button_type `Button ;  a_onclick call ]
              [ pcdata stage ]
          in
          div ~a:[ a_class [ "trigger" ]] [ input ; call  ]
        | `Float ->
          let input = input  ~a:[ a_input_type `Text ; a_placeholder "FLOAT" ] () in
          let call _ =
            let arg = Ys_dom.get_value input in
            ignore_result (%trigger_float (view.uid, stage, float_of_string arg))
          in
          let call =
            button
              ~a:[ a_button_type `Button ; a_onclick call ]
              [ pcdata stage ]
             in
             div ~a:[ a_class [ "trigger" ]] [ input ; call ]
        | `String ->
          let input = input  ~a:[ a_input_type `Text ; a_placeholder "STRING" ] () in
          let call _ =
            let arg = Ys_dom.get_value input in
            ignore_result (%trigger_string (view.uid, stage, arg))
          in
          let call =
            button
              ~a:[ a_button_type `Button ; a_onclick call ]
                 [ pcdata stage ]
          in
          div ~a:[ a_class [ "trigger" ]] [ input ; call ]
        | _ ->
          let input = input  ~a:[ a_input_type `Text ; a_placeholder "JSON" ] () in
          let call _ =
            let arg = Ys_dom.get_value input in
            ignore_result (%trigger_raw (view.uid, stage, arg))
          in
          let call =
            button
              ~a:[ a_button_type `Button ;  a_onclick call ]
              [ pcdata stage ]
          in
          div ~a:[ a_class [ "trigger" ]] [ input ; call ])
      bundle.triggers
  in

  (* members *)

  let members =

    let members = RList.init bundle.members in

    let format_member (member, tags) =

      let tag_input = input ~a:[ a_input_type `Text ; a_placeholder "Comma separated tags" ; a_value (String.concat "," tags) ]  () in
      let tag_update _ =
        let tags = Ys_dom.get_value tag_input in
        let tags = Regexp.split (Regexp.regexp ",") tags in
        let tags = List.filter (fun s -> s <> "") tags in
        Authentication.if_connected
          (fun _ -> rpc %update_member_tags (view.uid, member.View_member.uid, tags) (RList.update members))
      in
      let tag_update =
        button

          ~a:[ a_onclick tag_update ]
          [ pcdata "Update tags" ]
      in

      let remove _ =
        Authentication.if_connected
          (fun _ -> rpc %remove_member (view.uid, member.View_member.uid) (RList.update members))
      in
      let remove =
        button

          ~a:[ a_onclick remove ]
          [ pcdata "Remove" ]
      in

      div ~a:[ a_class [ "member" ; "box" ; ]] [
        div ~a:[ a_class [ "box-section" ]] [
          pcdata member.View_member.name
        ] ;
        div ~a:[ a_class [ "box-section" ]] [
          pcdata member.View_member.email
        ] ;
        div ~a:[ a_class [ "box-section" ]] [
          tag_input ;
        ] ;
        div ~a:[ a_class [ "box-action" ]] [
          tag_update ;
          remove ;
        ] ;
      ]
    in

    let add_member =
      let input_email = input ~a:[ a_input_type `Text ; a_placeholder "Email" ]  () in
      let input_tags = input ~a:[ a_input_type `Text ; a_placeholder "Comma separated tags" ]  () in
      let create _ =
        match Ys_dom.get_value input_email with
          "" -> Help.warning "Please specify a valid email"
        | _ as emails ->
          let tags = Ys_dom.get_value input_tags in
          let tags : string list = Regexp.split (Regexp.regexp ",") tags in
          let tags = List.filter (fun s -> s <> "") tags in
          Authentication.if_connected
            (fun _ -> rpc %add_members (view.uid, emails, tags) (fun m -> RList.update members m ; Ys_dom.set_value input_email "" ; Ys_dom.set_value input_tags ""))
      in
      let create =
        button
          ~a:[ a_button_type `Button ; a_onclick create ]
          [ pcdata "Create" ]
      in
      div ~a:[ a_class [ "add-member" ; "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [
          input_email
        ] ;
        div ~a:[ a_class [ "box-section" ]] [
          input_tags
        ] ;
        div ~a:[ a_class [ "box-action" ]] [
          create
        ]
      ]
    in

    div ~a:[ a_class [ "members" ]] [
      h2 [ pcdata "Members" ] ;
      RList.map_in_div_hd ~a:[ a_class [ "members-existing" ]] add_member format_member members ;
    ]

  in

  (* the messenger *)

  let messenger =
    match bundle.mailables with
      [] -> pcdata ""
    | _ as stages ->

      let textarea = Raw.textarea ~a:[ a_placeholder "Enter your message here" ] (pcdata "") in

      let stages = Raw.select (List.map (fun stage -> option (pcdata stage)) stages) in

      let send _ =
        match Ys_dom.get_value_textarea textarea, Ys_dom.get_value_select stages with
          "", _ -> Help.warning "please write something"
        | content, stage ->
          Authentication.if_connected
            (fun session ->
               rpc %create_message_and_trigger_stage (view.uid, session.member_uid, content, stage) (fun _ -> Ys_dom.set_value_textarea textarea ""))
      in

      let send =
        button

          ~a:[ a_onclick send ]
          [ pcdata "Send" ]
      in

      div ~a:[ a_class [ "messenger" ]] [
        h2 [ pcdata "Stage messenger" ] ;
        textarea ;
        div ~a:[ a_class [ "messenger-controls" ]] [ stages ; send ]
      ]
  in

  (* the little data store *)

  let data = RList.init bundle.data in

  let data_dom =
    let input_key = input ~a:[ a_input_type `Text ; a_placeholder "Key" ] () in
    let input_value = Raw.textarea  ~a:[ a_placeholder "Value" ] (pcdata "") in

    let add_data =
        let add _ =
        match Ys_dom.get_value input_key with
          "" -> Help.warning "Please specify a key"
        | _ as key ->
          Authentication.if_connected
            (fun _ ->
               rpc
               %set_value
                   (view.uid, key, Some (Ys_dom.get_value_textarea input_value))
                   (fun d -> RList.update data d ; Ys_dom.set_value input_key "" ; Ys_dom.set_value_textarea input_value ""))
      in
      let add =
        button
          ~a:[ a_button_type `Button ;
               a_onclick add ]
          [ pcdata "Add" ]
      in
      div ~a:[ a_class [ "add-data" ; "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [ input_key ] ;
        div ~a:[ a_class [ "box-section" ]] [ input_value ] ;
        div ~a:[ a_class [ "box-action" ]] [
          add
        ] ;
      ]
    in
    let format_data (key, value) =
      let remove _ =
        Authentication.if_connected
          (fun _ -> rpc %set_value (view.uid, key, None) (RList.update data))
      in
      let remove =
        button
          ~a:[ a_button_type `Button ;
               a_onclick remove ]
          [ pcdata "Remove" ]
      in
      let edit _ =
        Ys_dom.set_value input_key key ;
        Ys_dom.set_value_textarea input_value value
      in
      let edit =
        button
          ~a:[ a_button_type `Button ;
               a_onclick edit ]
          [ pcdata "Edit" ]
      in

      div ~a:[ a_class [ "data-item" ; "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [
          pcdata key ; pcdata " -> " ; pcdata (if String.length value > 1024 then String.sub value 0 1024 else value);
        ] ;
        div ~a:[ a_class [ "box-action" ]] [
          edit ;
          remove ;
        ]
      ]
    in
    div ~a:[ a_class [ "data" ]] [
      h2 [ pcdata "Data" ] ;
      RList.map_in_div_hd add_data format_data data
    ]
  in

  (* parameters *)

  let parameters =
    div ~a:[ a_class [ "parameters" ]] [
      h2 [ pcdata "Parameters" ] ;
      div (List.map
             (fun parameter ->
                R.node
                  (S.map
                     (fun existing_data ->
                        let current_value = try List.assoc parameter.View_playbook.label existing_data with _ -> "" in
                        let input_value = input ~a:[ a_input_type `Text ; a_placeholder "Value" ; a_value current_value ] () in
                        let add _ =
                          Authentication.if_connected
                            (fun _ ->
                               rpc
                               %set_value
                                   (view.uid, parameter.View_playbook.key, Some (Ys_dom.get_value input_value))
                                   (fun d -> RList.update data d))
                        in
                        let add =
                          button
                            ~a:[ a_button_type `Button ; a_onclick add ]
                            [ pcdata "Add" ]
                        in
                        div ~a:[ a_class [ "parameter" ]] [
                          label [ pcdata parameter.View_playbook.label ] ;
                          input_value ;
                          add
                        ]
                     )
                     (RList.channel data))
             )
             view.playbook.View_playbook.parameters)
    ]

  in

  let name =
    let name = Raw.textarea (pcdata view.name) in
    let update_name _ =
      Authentication.if_connected ~mixpanel:("society-leader-update-name", [ "uid", Ys_uid.to_string view.uid ])
        (fun _ ->
           rpc %update_name (view.uid, Ys_dom.get_value_textarea name) (fun _ -> Help.warning "name saved"))
    in
    let update_name =
      button
        ~a:[ a_button_type `Button ; a_onclick update_name ]
        [ pcdata "Update name" ]
    in
    div ~a:[ a_class [ "name" ]] [
      h2 [ pcdata "Name" ] ;
      div ~a:[ a_class [ "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [ name ] ;
        div ~a:[ a_class [ "box-action" ]] [ update_name ] ;
      ]
    ]
  in

  let description =
    let description = Raw.textarea (pcdata view.description) in
    let update_description _ =
      Authentication.if_connected ~mixpanel:("society-leader-update-description", [ "uid", Ys_uid.to_string view.uid ])
        (fun _ ->
           rpc %update_description (view.uid, Ys_dom.get_value_textarea description) (fun _ -> Help.warning "description saved"))
    in
    let update_description =
      button
        ~a:[ a_button_type `Button ; a_onclick update_description ]
        [ pcdata "Update description" ]
    in
    div ~a:[ a_class [ "description" ]] [
      h2 [ pcdata "Description" ] ;
      div ~a:[ a_class [ "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [ description ] ;
        div ~a:[ a_class [ "box-action" ]] [ update_description ] ;
      ]
    ]
  in

  let supervisor =
    let supervisor, update_supervisor_value = S.create view.supervisor in
    let email = input ~a:[ a_input_type `Text ; a_value (view.supervisor.View_member.email) ] () in
    let _ =
      S.map
        (fun supervisor -> Ys_dom.set_value email supervisor.View_member.email)
        supervisor
    in
    let update_supervisor _ =
      Authentication.if_connected ~mixpanel:("society-leader-update-supervisor", [ "uid", Ys_uid.to_string view.uid ])
        (fun _ ->
           rpc
           %update_supervisor
               (view.uid, Ys_dom.get_value email)
               (fun supervisor ->
                  update_supervisor_value supervisor ;
                  Help.warning "supervisor updated"))
    in
    let update_supervisor =
      button
        ~a:[ a_button_type `Button ; a_onclick update_supervisor ]
        [ pcdata "Update supervisor" ]
    in
    div ~a:[ a_class [ "supervisor" ]] [
      h2 [ pcdata "Supervisor" ] ;
      div ~a:[ a_class [ "box" ]] [
        div ~a:[ a_class [ "box-section" ]] [
          email
        ] ;
        div ~a:[ a_class [ "box-action" ]] [ update_supervisor ] ;
      ]
    ]

  in

  (* the societies *)

  let societies =
    let societies = RList.init bundle.societies in
    let add_society =
      let playbook = input ~a:[ a_input_type `Text  ; a_placeholder "Playbook" ] () in
      let name = input ~a:[ a_input_type `Text ; a_placeholder "Name" ] () in
      let description = Raw.textarea ~a:[ a_placeholder "Description" ] (pcdata "") in
      let create _ =
        Help.warning "use the manage interface"
      in
      let create =
        button
          ~a:[ a_button_type `Button ;
               a_onclick create ]
          [ pcdata "Create" ]
      in
      div ~a:[ a_class [ "add-society" ; "add-box" ]] [
        div ~a:[ a_class [ "box-section" ]] [ playbook ] ;
        div ~a:[ a_class [ "box-section" ]] [ name ] ;
        div ~a:[ a_class [ "box-section" ]] [ description ] ;
        div ~a:[ a_class [ "box-action" ]] [ create ] ;
      ]
    in
    let format_society society =
      div ~a:[ a_class [ "box" ]] [
        pcdata society.View_society.name
      ]
    in
    div ~a:[ a_class [ "societies" ]] [
      h2 [ pcdata "Societies" ] ;
      RList.map_in_div_hd add_society format_society societies
    ]
  in

  (* the main dom *)

  div ~a:[ a_class [ "society-leader" ]] [
    div [
      button ~a:[ a_button_type `Button ;
                  a_onclick (fun _ -> Service.goto (Service.Manage (bundle.view.shortlink, bundle.view.uid, Service.ManageHome))) ]
        [ pcdata "Manage" ]
    ] ;
    mode ;
    div ~a:[ a_class [ "society-leader-upper" ; "clearfix" ]] [
      div ~a:[ a_class [ "logs"; "left" ]] [  stack ; logs ] ;
      graph ;
    ] ;
    div ~a:[ a_class [ "society-leader-lower" ]]

      [
        div ~a:[ a_class [ "mailboxes" ]] [
          h2 [ pcdata "Mailboxes" ] ;
          div ~a:[ a_class [ "clearfix" ]] [
             div ~a:[ a_class [ "inbox-outer" ; "left" ]] [
               h3 [ pcdata "Inbox" ] ;
               inbox ;
             ] ;
             div ~a:[ a_class [ "outbox-outer" ; "left" ]] [
               h3 [ pcdata "Outbox" ] ;
               outbox
             ] ;
           ] ;
        ] ;

        div ~a:[ a_class [ "triggers" ]] [
          h2 [ pcdata "Triggers" ] ;
          div ~a:[ a_class [ "triggers-controls"; "clearfix" ]] triggers
        ] ;

        members ;
        societies ;
        messenger ;
        data_dom ;
        parameters ;
        name ;
        description ;
        supervisor
      ]
  ]


}}
