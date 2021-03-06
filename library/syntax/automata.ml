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


open Camlp4
open PreCast
open Ast

module StringSet = Set.Make(String)

type opt = Tickable | Mailbox | MessageStrategies of string list | ExternalMailbox | InboundType of ctyp

module Vertex = struct

  type t =
    {
      stage: string ;
      options: opt list ;
      path : string list ;
    }

   let compare v1 v2 = Pervasives.compare v1.stage v2.stage
   let hash v = Hashtbl.hash v.stage
   let equal v1 v2 = v1.stage = v2.stage

   let options v = v.options
   let stage v = v.stage

   let call _loc v =
     Pa_tools.wrap_with_modules _loc <:expr< $lid:v.stage$ >> v.path

   let path v = v.path

   let is_mailable v =
     List.exists (function MessageStrategies _ -> true | _ -> false) v.options

end

(* representation of an edge *)

module Edge = struct
  type t = ctyp
  let compare = Pervasives.compare
  let default = let _loc = Loc.ghost in <:ctyp< _ >>
  let to_string ty =
    let rec ty_to_string = function
      <:ctyp< unit >> -> "()"
    | <:ctyp< int >> -> "int"
    | <:ctyp< email >> -> "int"
    | <:ctyp< int64 >> -> "int64"
    | <:ctyp< string >> -> "string"
    | <:ctyp< float >> -> "float"
    | <:ctyp< ($t1$ * $t2$ * $t3$ * $t4$ * $t5$) >> -> Printf.sprintf "%s, %s, %s, %s, %s" (ty_to_string t1) (ty_to_string t2) (ty_to_string t3) (ty_to_string t4) (ty_to_string t5)
    | <:ctyp< ($t1$ * $t2$ * $t3$ * $t4$) >> -> Printf.sprintf "%s, %s, %s, %s" (ty_to_string t1) (ty_to_string t2) (ty_to_string t3) (ty_to_string t4)
    | <:ctyp< ($t1$ * $t2$ * $t3$) >> -> Printf.sprintf "%s, %s, %s" (ty_to_string t1) (ty_to_string t2) (ty_to_string t3)
    | <:ctyp< ($t1$ * $t2$) >> -> Printf.sprintf "%s, %s" (ty_to_string t1) (ty_to_string t2)
    | _ -> ""
    in
    match ty with
      <:ctyp< `$uid:constr$ >> -> constr
    | <:ctyp< `$uid:constr$ of $args$ >> -> Printf.sprintf "%s(%s)" constr (ty_to_string args)
    | _ -> "email out to member"

end

module G = Graph.Persistent.Digraph.ConcreteBidirectionalLabeled(Vertex)(Edge)

let static_type = function
  | "init__" -> Some `Unit
  | "new_member__" -> Some `Int
  | "remind__" -> Some `Int
  | _ -> None

let extract_inbound_type _loc automata stage =
  (* very important: force typing for stages defined in Api.Stages *)
  let inferred =
    match static_type (Vertex.stage stage) with
    | Some `Unit -> Some <:ctyp< unit >>
    | Some `Int -> Some <:ctyp< int >>
    | _ ->
      let edges =
        G.fold_pred_e
          (fun edge acc ->
             match G.E.label edge with
               <:ctyp< _ >> -> acc
             | _ as edge -> edge :: acc)
          automata
          stage
          []
    in
    match edges with
      <:ctyp< `$uid:_$ of email >> :: _ -> Some <:ctyp< int >>
    | <:ctyp< `$uid:constr$ of $t$ >> :: _ -> Some t
    | <:ctyp< `$uid:constr$ >> :: _ -> Some <:ctyp< unit >>
    | _ ->
      match List.mem Tickable (Vertex.options stage) with
        true -> Some <:ctyp< unit >>
      | false ->
        match List.mem Mailbox (Vertex.options stage) with
          true -> Some <:ctyp< int >>
        | false -> None in

  let casted =
    List.fold_left
      (fun acc -> function
         | InboundType ctyp -> Some ctyp
         | _ -> acc)
      None
      (Vertex.options stage)
  in

  match inferred, casted with
  | None, Some ctyp -> Some ctyp
  | None, None -> None
  | Some ctyp, None -> Some ctyp
  | Some ty1, Some ty2 when ty1 = ty2 -> Some ty1
  | _ ->
    (* here we should fail *)
    failwith (Printf.sprintf "mismatch between inferred and casted inbound types for stage %s" (Vertex.stage stage))


let outbound_types _loc automata =
  G.fold_vertex
    (fun stage acc ->

       let edges =
         G.fold_succ_e
           (fun edge acc ->
              match G.E.label edge with
                <:ctyp< _ >> -> acc
              | <:ctyp< `$uid:_$ of email >> -> acc
              (* | <:ctyp< `Message of int >> -> acc *)
              | _ as edge -> edge :: acc)
           automata
           stage
           []
       in
       let t = <:ctyp< [= $list:edges$ ] >> in

       <:str_item<
         $acc$ ;
         type $lid:"outbound_" ^ Vertex.stage stage$ = $t$ ;
       >>)
    automata
    <:str_item< open Bin_prot.Std >>

let inbound_serializers _loc automata =
  G.fold_vertex
    (fun stage acc ->
       (* we look at all the inbound edges for this stage *)
       match extract_inbound_type _loc automata stage with
         None ->
         Printf.eprintf "warning: stage %s isn't reachable, we can't infer the type\n" (Vertex.stage stage) ;
         acc
       | Some t ->

         let tp = TyDcl(_loc, Printf.sprintf "inbound_%s" (Vertex.stage stage), [], t, []) in

         let open Pa_deriving_common.Utils in
         let open Pa_deriving_common.Base in
         let open Pa_deriving_common.Type in
         let open Pa_deriving_common.Extend in

         let decls = display_errors _loc Translate.decls tp in
         let module U = Untranslate(struct let _loc = _loc end) in

         let cl = "Yojson" in
	 let cl = find cl in
	 let ms = derive_str _loc decls cl in

         <:str_item<
              $acc$ ;

              type $lid:Printf.sprintf "inbound_%s" (Vertex.stage stage)$ = $t$ ;

              $ms$ ;

              value $lid:"serialize_" ^ Vertex.stage stage$ v =
                 $uid:"Yojson_inbound_" ^ (Vertex.stage stage)$.to_string v ;

              value $lid:"deserialize_" ^ Vertex.stage stage$ json =
                 $uid:"Yojson_inbound_" ^ (Vertex.stage stage)$.from_string json ;

             >>
    )
    automata
    <:str_item< open Bin_prot.Std >>

let outbound_dispatcher allow_none _loc automata stage schedule =
  G.fold_succ_e
    (fun edge acc ->
       let dest = Vertex.stage (G.E.dst edge) in
       match G.E.label edge with
      (*   | <:ctyp< `$uid:_$ of email >> -> acc (* messages can't be emitted from the stage *) *)
       (* | <:ctyp< `Message of int >> -> acc (* messages transitions can't be emitted from the stage itself *) *)
       | <:ctyp< `$uid:constr$ >> ->
          if allow_none then
           <:match_case< `$uid:constr$ ->
                                   let args = $lid:"serialize_" ^ dest$ () in
                                   Some Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ ; created_on = Ys_time.now () }) >> :: acc
         else
           <:match_case< `$uid:constr$ ->
                                   let args = $lid:"serialize_" ^ dest$ () in
                                   Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ ; created_on = Ys_time.now () }) >> :: acc
       | <:ctyp< `$uid:constr$ of $args$ >> ->
         if allow_none then
           <:match_case< `$uid:constr$ args ->
                                   let args = $lid:"serialize_" ^ dest$ args in
                                   Some Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ ; created_on = Ys_time.now () }) >> :: acc
         else
           <:match_case< `$uid:constr$ args ->
                                   let args = $lid:"serialize_" ^ dest$ args in
                                   Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ ; created_on = Ys_time.now () }) >> :: acc
       | _ -> acc)
    automata
    stage
    (if allow_none then [ <:match_case< `None -> None >> ] else [])

let steps _loc automata =
  G.fold_vertex
    (fun stage acc ->
       match extract_inbound_type _loc automata stage with
         None -> acc
       | Some t ->
         (* here we have the guarantee that the inbound type has been declared *)
         let _loc = Loc.mk (Loc.file_name _loc ^ ": " ^ Vertex.stage stage ^ "(steps)") in
         let dispatcher = outbound_dispatcher true _loc automata stage <:expr< Immediate >> in

         <:str_item<
           $acc$ ;
           value $lid:"step_" ^ Vertex.stage stage$ context args_serialized =
              Lwt.catch
                 (fun () ->
                    do {
                       context.log_info "calling stage %s" $str:Vertex.stage stage$ ;
                       let args = $lid:"deserialize_" ^ Vertex.stage stage$ args_serialized in
                       Lwt.bind
                          ($Vertex.call _loc stage$ context args)
                          (fun r -> Lwt.return (match r with [ $list:dispatcher$ ])) })
                 (fun exn ->
                    do {
                       context.log_error ~exn "exception caught in stage %s: %s" $str:Vertex.stage stage$ (Printexc.to_string exn) ;
                       Lwt.return_none })

         >>)
    automata
    <:str_item< >>

let dispatch _loc automata =
  let cases =
    G.fold_vertex
      (fun stage acc ->
         match extract_inbound_type _loc automata stage with
           None ->
           Printf.eprintf "skipping dispatch for stage %s, no inbound type\n" (Vertex.stage stage) ;
           flush stdout ;
           acc
         | Some _ ->
           let dispatcher = outbound_dispatcher false _loc automata stage <:expr< Delayed timeout >> in

           <:match_case< $str:Vertex.stage stage$ ->

                        let module Stage_Specifics =
                          struct
                            value stage = $str:Vertex.stage stage$ ;
                            type outbound = $lid:"outbound_"^ Vertex.stage stage$ ;
                            value outbound_dispatcher timeout = fun [ $list:dispatcher$ ] ;
                          end in

                        let module Context = Factory(Stage_Specifics) in

                        let context = Context.context in

                        $lid:"step_" ^ Vertex.stage stage$ context call.Ys_executor.args >> :: acc
      )
      automata
      [ <:match_case< _ -> failwith "unknown stage" >> ] in
  <:str_item<
    value step (module Factory: Api.STAGE_CONTEXT_FACTORY) call =
      match call.Ys_executor.stage with [ $list:cases$ ] ;
  >>

let triggers _loc automata =
  G.fold_vertex
    (fun stage acc ->
       (* we can only guess the input format from the inbound edges *)
       (* if there is no inbound edge, we can hope that the inbound type is unit, as it must be a cronable stage *)
       let default =
         match List.mem Tickable (Vertex.options stage) with
           true -> Some `Unit
         | false ->
           match List.mem Mailbox (Vertex.options stage) with
             true -> Some `Int
           | false -> static_type (Vertex.stage stage)
       in

       let extract_type = function
           <:ctyp< int >> -> Some `Int
         | <:ctyp< int64 >> -> Some `Int64
         | <:ctyp< string >> -> Some `String
         | <:ctyp< email >> -> Some `Int
         | <:ctyp< float >> -> Some `Float
         | _ -> Some `Raw
       in

       let rec type_to_expr = function
         | `Unit -> <:expr< `Unit >>
         | `Int -> <:expr< `Int >>
         | `Int64 -> <:expr< `Int64 >>
         | `String -> <:expr< `String >>
         | `Float -> <:expr< `Float >>
         | `Raw -> <:expr< `Raw >>
       in

       let input_type =
         G.fold_pred_e
           (fun transition acc ->
              match G.E.label transition with
              | <:ctyp< `$uid:constr$ >> -> Some `Unit
              | <:ctyp< `$uid:constr$ of $t1$ >> -> extract_type t1
              | _ -> None)
           automata
           stage
           default in

       let stage = Vertex.stage stage in
       match input_type with
       | None -> Printf.eprintf "skipping stage %s in the triggers, type unknown\n" stage ; flush stdout ; acc
       | Some ty -> <:expr< [ ($type_to_expr ty$, $str:stage$) :: $acc$ ] >>)
    automata
    <:expr< [] >>

let mailables _loc automata =
  let stages = G.fold_vertex
      (fun stage acc ->
         let is_mailable = G.fold_succ_e
             (fun transition acc ->
                match G.E.label transition with
                  <:ctyp< `$uid:_$ of email >> -> true
                | _ -> acc)
             automata
             stage
             false
         in
         if is_mailable || Vertex.is_mailable stage then
           Vertex.stage stage :: acc
         else acc)
      automata
      [] in
  List.fold_left
    (fun acc s -> <:expr< [ $str:s$ :: $acc$ ] >>)
    <:expr< [] >>
    stages

let email_actions _loc automata =
  G.fold_vertex
    (fun stage acc ->
       let options =
         G.fold_succ_e
           (fun transition acc ->
              match G.E.label transition with
                <:ctyp< `$uid:label$ of email >> -> label :: acc
              | _ -> acc)
           automata
           stage
           []
       in
       match options with
         [] -> acc
       | _ as options ->
         let options = List.fold_left (fun acc s -> <:expr< [ $str:s$ :: $acc$ ] >>) <:expr< [] >> options in
         <:expr< [ ($str:Vertex.stage stage$, $options$) :: $acc$ ] >>
    )
    automata
    <:expr< [] >>

let dispatch_message_manually _loc automata =
  let cases =
    G.fold_vertex
      (fun stage acc ->
         let options =
           G.fold_succ_e
             (fun transition acc ->
                match G.E.label transition with
                  <:ctyp< `$uid:label$ of email >> -> (label, Vertex.stage (G.E.dst transition)) :: acc
                | _ -> acc)
             automata
             stage
             []
         in
         match options with
           [] -> acc
         | _ as options ->
           let options =
             List.map
               (fun (tag, destination) ->
                  <:match_case< $str:tag$ -> Some (Ys_executor.({
                               stage = $str:destination$ ;
                               args = $lid:"serialize_" ^ destination$ message ;
                               schedule = Immediate ;
                               created_on = Ys_time.now ()  })) >>
               )
               options
           in
           let options = options @ [ <:match_case< _ -> None >> ] in
           <:match_case< $str:Vertex.stage stage$ ->
             match tag with [ $list:options$ ]
           >> :: acc
      )
      automata
      [ <:match_case< _ -> None >> ]
  in
  <:str_item< value dispatch_message_manually message stage tag =
             let _ = Lwt_log.ign_info_f "dispatch_message_manually: %d , stage is %s, tag is %s" message stage tag in
    match stage with [ $list:cases$ ]
  >>

let dispatch_message_automatically _loc automata =
  let cases =
    G.fold_vertex
      (fun stage acc ->
         let _loc = Loc.mk (Loc.file_name _loc ^ ": " ^ Vertex.stage stage ^ "(automatic dispatch)") in
         let dispatcher = outbound_dispatcher false _loc automata stage <:expr< Immediate >> in

         let strategies =
           List.fold_left
             (fun acc -> function
                | MessageStrategies strats ->
                  List.fold_left (fun acc strat -> StringSet.add strat acc) acc strats
                | _ -> acc)
             StringSet.empty
             (Vertex.options stage)
         in
         let strategies = StringSet.elements strategies in
         let apply_strategies =
           List.fold_left
             (fun acc strategy ->
                <:expr<
                       Lwt.bind
                       ($lid:strategy$ message)
                       (fun
                         [ None -> $acc$
                         | Some reply ->
                       let _ = Lwt_log.ign_info_f "found a reply" in
                            (* then we should be able to turn reply into a call *)
                           Lwt.return (Some (match reply with [ $list:dispatcher$ ])) ]) >>)
             <:expr< Lwt.return_none >>
             strategies
         in
         <:match_case< $str:Vertex.stage stage$ ->
                      let _ = Lwt_log.ign_info_f "the message is being routed from stage %s with %s strategies" $str:Vertex.stage stage$ $str:string_of_int (List.length strategies)$ in
                      $apply_strategies$ >> :: acc)
      automata
      [ <:match_case< _ -> Lwt.return_none >> ]
  in
  <:str_item< value dispatch_message_automatically message stage =
    let _ = Lwt_log.ign_info_f "dispatch_message_automatically: %d , stage is %s" message stage in
    match stage with [ $list:cases$ ]
  >>

module Dot = Graph.Graphviz.Dot(struct

    include G

    let edge_attributes edge =
      match E.label edge with
      | ctyp -> [ `Label (Edge.to_string ctyp) ; `Arrowhead `Normal ; `Color 4711 ]

    let default_edge_attributes _ = []
    let get_subgraph _ = None
    let vertex_attributes v =
      match List.mem ExternalMailbox (Vertex.options v) with
        false -> [ `Shape `Ellipse ; `HtmlLabel (Vertex.stage v) ]
      | true -> [ `Shape `Diamond ; `HtmlLabel (Vertex.stage v) ]

    let vertex_name v = Vertex.stage v
    let default_vertex_attributes _ = []
    let graph_attributes _ = [ ]

  end)


let inject_mailboxes graph =
  (* we add fake edges so that the printed graph show emails as external edges *)
  G.fold_vertex
    (fun stage acc ->
       let is_mailable =
         G.fold_succ_e
           (fun transition acc ->
              match G.E.label transition with
                <:ctyp< `$uid:_$ of email >> -> true
              | _ -> acc)
           graph
           stage
           (Vertex.is_mailable stage)
       in
       match is_mailable with
         false ->
         let acc = G.add_vertex acc stage in
         G.fold_succ_e
           (fun edge acc -> G.add_edge_e acc edge)
           graph
           stage
           acc
       | true ->
         let mailbox =
           {
             Vertex.stage = "mailbox_" ^ Vertex.stage stage ;
             options = [ ExternalMailbox ] ;
             path = [] ;
           } in
         let acc = G.add_vertex acc stage in
         let acc = G.add_vertex acc mailbox in
         let acc =
           G.add_edge acc stage mailbox
         in
         G.fold_succ_e
           (fun edge acc ->
              match G.E.label edge with
                <:ctyp< `$uid:_$ of email >> -> G.add_edge_e acc (G.E.create mailbox (G.E.label edge) (G.E.dst edge))
              | _ -> G.add_edge_e acc edge)
           graph
           stage
           acc)
    graph
    G.empty


let graph_to_string graph =
  let graph = inject_mailboxes graph in
  let buffer = Buffer.create 1024 in
  let formatter = Format.formatter_of_buffer buffer in
  Dot.fprint_graph formatter graph;
  Format.pp_print_flush formatter () ;
  Buffer.contents buffer

let dump_automata _loc automata =
  let original_file = Loc.file_name _loc in
  let original_prefix = Filename.chop_extension original_file in
  Printf.eprintf "dumping the automata, prefix is %s\n" original_prefix ; flush stdout ;
  let destination_file = original_prefix ^ ".automata" in
  let oc = open_out_bin destination_file in
  Marshal.to_channel oc automata [] ;
  close_out oc

let print_automata _loc automata =
  let automata = inject_mailboxes automata in
  let original_file = Loc.file_name _loc in
  let original_prefix = Filename.chop_extension original_file in
  let original_prefix = Filename.concat (Filename.dirname original_prefix) ("dot_" ^ Filename.basename original_prefix) in
  Printf.eprintf "printing the automata, prefix is %s\n" original_prefix ; flush stdout ;
  let destination_file = original_prefix ^ ".dot" in
  let oc = open_out_bin destination_file in
  let () = Dot.output_graph oc automata in
  close_out oc

let load_automata _loc import =
  (* we expect the import to be in the same folder *)
  let original_dir = Filename.dirname (Loc.file_name _loc) in
  let binary_file = Filename.concat original_dir (import ^ ".automata") in
  let ic = open_in_bin binary_file in
  let graph = (Marshal.from_channel ic : G.t) in
  close_in ic ;
  graph


let extract_names _loc automata =
  G.fold_vertex
    (fun stage acc ->
       <:str_item<
         value $lid:Vertex.stage stage$ = $str:Vertex.stage stage$ ;
         $acc$ ; >>)
    automata
    <:str_item<>>
