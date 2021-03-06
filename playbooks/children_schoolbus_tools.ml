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

open Printf

open Lwt
open Api

open Children_schoolbus_types

let key_profile = sprintf "profile-%d"

let get_profile context member =
  match_lwt context.get ~key:(key_profile member) with
    None -> return_none
  | Some profile ->
    try
      return (Some (Yojson_profile.from_string profile))
    with _ -> return_none

let set_profile context profile =
  context.set ~key:(key_profile profile.uid) ~value:(Yojson_profile.to_string profile)


let to_date_json date =
  {
    year = 2016 ;
    month = 5 ;
    day = 27 ;
  }

let to_activity_json activity_uid =
  lwt activity_min_age_in_months, activity_max_age_in_months,
      activity_title, activity_description, activity_summary, date = $activity(activity_uid)->(min_age_in_months, max_age_in_months, title, description, summary, date)
  in
  let activity_date = to_date_json date in
  return
    {
      activity_uid ;
      activity_reference = "dummy" ;
      activity_min_age_in_months ;
      activity_max_age_in_months ;
      activity_date ;
      activity_title ;
      activity_description ;
      activity_summary ;
      activity_steps = [] ;
      activity_status = Suggestion { activity_suggestion = "" } ;
      activity_attachments = [] ;
      activity_bookings = [] ;
    }
