(*
 * core - payments
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

(* some tags *)

let key_payment = "core-payment-payment"
let tag_has_payments_pending = sprintf "corepaymentshaspending%d"
let timer_reminder = sprintf "corepaymentsreminder%d%d"

(* the stages *)

let request_payment context (member, label, amount, evidence_message) =
  context.log_info "requesting payment to member %d, amount is %f" member amount ;
  lwt evidence = $message(evidence_message)->attachments in
  match_lwt
    context.request_payment
      ~member
      ~label
      ~evidence
      ~amount
      ~on_success:(fun payment -> `PaymentSuccess(member, payment))
      ~on_failure:(fun payment -> `PaymentFailure(member, payment)) with
  | None ->
    context.log_error "couldn't issue payment for %d, panic" member ;
    return (`AlertSupervisor (member, label, amount))
  | Some payment ->
    lwt payment_direct_link = context.payment_direct_link ~payment in
    lwt amount = context.payment_amount ~payment in
    let content =
      match evidence with
        [] ->
        [
          pcdata "Greetings," ; br () ;
          br ()  ;
          pcdata "Thanks for your participation to " ; pcdata context.society_name ; pcdata ", I hope you enjoyed it!" ; br () ;
          br () ;
          pcdata "Your share ends up being "; pcdata (Printf.sprintf "$%.2f" amount) ; pcdata ". Would you mind visiting the secured link below & authorize the payment?" ; br () ;
          br () ;
          Raw.a ~a:[ a_href (uri_of_string (fun () -> payment_direct_link)) ] [ pcdata payment_direct_link ] ; br () ;
          br () ;
          pcdata "By the way, payments are secured by Stripe and only Stripe fees are added to the original receipt." ; br () ;
          br () ;
          pcdata "Let me know if you have any questions," ; br () ;
          br () ;
          pcdata "Thanks!" ;
        ]
      | _ ->
        [
          pcdata "Greetings," ; br () ;
          br () ;
          pcdata "Thanks for your participation to " ; pcdata context.society_name ; pcdata ", I hope you enjoyed it!" ; br () ;
          br () ;
          pcdata "Your share ends up being "; pcdata (Printf.sprintf "$%.2f" amount) ; pcdata ". Would you mind visiting the secured link below & authorize the payment?" ; br () ;
          br () ;
          Raw.a ~a:[ a_href (uri_of_string (fun () -> payment_direct_link)) ] [ pcdata payment_direct_link ] ; br () ;
          br () ;
          pcdata "The receipt for group is attached. " ; pcdata "Payments are secured by Stripe and only Stripe fees are added to the original receipt." ; br () ;
          br () ;
          pcdata "Let me know if you have any questions," ; br () ;
          br () ;
          pcdata "Thanks!" ;
        ]
    in
    lwt _ =
      context.message_member
        ~member
        ~attachments:evidence
        ~data:[ key_payment, Ys_uid.to_string payment ]
        ~subject:label
        ~content
        ()
    in
    lwt _ =
      context.tag_member ~member ~tags:[ tag_has_payments_pending payment ]
    in
    lwt _ =
      context.set_timer
        ~label:(timer_reminder member payment)
        ~duration:(Calendar.Period.lmake ~hour:24 ())
        (`RemindMemberOfPayment (member, label, payment, 0))
    in
    return `None

let payment_alert_supervisor context (member, label, amount) =
  context.log_warning "alerting supervisor for member %d, label %s, amount %f" member label amount ;
  lwt email = $member(member)->preferred_email in
  lwt _ =
    context.message_supervisor
      ~subject:"Couldn't create payment"
      ~content:[
        pcdata "Greetings," ; br () ;
        br () ;
        pcdata "I couldn't create an payment for " ; pcdata email ; pcdata ", amount is " ; pcdata (Printf.sprintf "$%.2f" amount) ; pcdata "." ; br () ;
        br () ;
        pcdata "The label of the payment was:" ; br () ;
        br () ;
        i [ pcdata label ] ;
        br () ;
      ]
      ()
  in
  return `None

let remind_member_of_payment context (member, label, payment, attempts) =
  if attempts > 2 then
    begin
      context.log_info "member %d hasn't responded in %d attempts" member attempts ;
      lwt email = $member(member)->preferred_email in
      lwt _ =
        context.message_supervisor
          ~data:[ key_payment, Ys_uid.to_string payment ]
          ~subject:(Printf.sprintf "Missed payment for %s" label)
          ~content:[
            pcdata "Greetings," ; br () ;
            br () ;
            pcdata "Member " ; pcdata email ; pcdata " hasn't responded about payment " ; pcdata (Ys_uid.to_string payment) ; pcdata "." ; br () ;
            br () ;
            pcdata "The label of the payment is:" ; br () ;
            br () ;
            i [ pcdata label ] ; br () ;
            br () ;
            pcdata "You're needed" ; br () ;
          ]
          ()
      in
      return `None
    end
  else
    lwt payment_direct_link = context.payment_direct_link ~payment in
    lwt _ =
      context.message_member
        ~member
        ~data:[ key_payment, Ys_uid.to_string payment ]
        ~subject:label
        ~content:[
          pcdata "Greetings," ; br ();
          br () ;
          pcdata "Sorry for the reminder; would you mind visiting the link below to settle this transaction?" ; br () ;
          br () ;
          Raw.a ~a:[ a_href (uri_of_string (fun () -> payment_direct_link)) ] [ pcdata payment_direct_link ] ; br () ;
          br () ;
          pcdata "If you have any question, please get in touch!" ; br ()
        ]
        ()
    in
    lwt _ =
      context.set_timer
        ~label:(timer_reminder member payment)
        ~duration:(Calendar.Period.lmake ~hour:24 ())
        (`RemindMemberOfPayment (member, label, payment, attempts + 1))
    in
    return `None

let payment_success context (member, payment) =
  context.log_info "payment success from member %d" member ;
  lwt _ = context.cancel_timers ~query:(timer_reminder member payment) in
  lwt _ = context.untag_member ~member ~tags:[ tag_has_payments_pending payment ] in
  lwt _ =
    context.message_member
      ~member
      ~subject:"Thanks!"
      ~content:[
        pcdata "Thanks for the payment!"
      ]
      ()
  in
  lwt _ =
    context.message_supervisor
      ~subject:"You got a payment"
      ~content:[
        pcdata "Good news, you got a payment" ; br () ;
        br () ;
      ]
      ()
  in
  return `None

let do_nothing _ _ =
  return `None

let remind_all context () =
  let open Ys_uid in
  context.log_info "reminding users about all the missing invoices" ;
  lwt payments = $society(context.society)->payments in
  lwt payments =
    Lwt_list.fold_left_s
      (fun payments (`Payment, uid) ->
         match_lwt $payment(uid)->(state, member) with
          | Object_payment.Paid, _ -> return payments
          | _, member ->
            let v =
              try
                UidMap.find member payments
              with _ -> [] in
            return (UidMap.add member (uid :: v) payments))
      UidMap.empty
      payments in
  let payments = UidMap.bindings payments in
  lwt _ =
    Lwt_list.iter_s
      (fun (member, payments) ->
         let payments = Ys_list.take 10 payments in
         lwt links =
           Lwt_list.map_s
             (fun payment ->
                lwt payment_direct_link = context.payment_direct_link ~payment in
                lwt label = $payment(payment)->label in
                return (li [ Raw.a ~a:[ a_href (uri_of_string (fun () -> payment_direct_link)) ] [ pcdata label ]]))
             payments
         in

         lwt _ =
           context.message_member
             ~member
             ~subject:(Printf.sprintf "(Reminder) You have %d payment(s) requests on Accretio" (List.length payments))
             ~content:[
               pcdata "Greetings," ; br ();
               br () ;
               pcdata "Sorry for the reminder but it looks like " ;
               pcdata (string_of_int (List.length payments)) ; pcdata " payment(s) are waiting to be settled. Would you mind checking out the link(s) below?" ; br () ;
               br () ;
               ul links ;
               br () ;
               pcdata "If you have any question, please get in touch!" ; br ()
             ]
             ()
         in
         return_unit)
      payments
   in
   return `None

(* the plumbing *)

COMPONENT

 request_payment ~> `AlertSupervisor of (int * string * float) ~> payment_alert_supervisor
 request_payment ~> `RemindMemberOfPayment of (int * string * int * int) ~> remind_member_of_payment ~> `RemindMemberOfPayment of (int * string * int * int) ~> remind_member_of_payment
 request_payment ~> `PaymentSuccess of (int * int) ~> payment_success
 request_payment ~> `PaymentFailure of (int * int) ~> do_nothing


 *remind_all
