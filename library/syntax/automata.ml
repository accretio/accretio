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

module Vertex = struct
  type t = string * [ `Tickable | `Mailbox ] list
   let compare v1 v2 = Pervasives.compare (fst v1) (fst v2)
   let hash v = Hashtbl.hash (fst v)
   let equal v1 v2 = (fst v1) = (fst v2)
   let lident v = fst v
end

(* representation of an edge *)

module Edge = struct
  type t = ctyp
  let compare = Pervasives.compare
  let default = let _loc = Loc.ghost in <:ctyp< _ >>
  let to_string = function
    | <:ctyp< `$uid:constr$ >> -> constr
    | <:ctyp< `$uid:constr$ of $args$ >> -> Printf.sprintf "%s()" constr
    | _ -> "edge"
end

module G = Graph.Persistent.Digraph.ConcreteBidirectionalLabeled(Vertex)(Edge)


let extract_inbound_type _loc automata stage =
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
  | <:ctyp< `$uid:constr$ of $t$ >> :: _ -> Some t
  | <:ctyp< `$uid:constr$ >> :: _ -> Some <:ctyp< unit >>
  | _ ->
    match List.mem (`Tickable) (snd stage) with
      false -> None
    | true -> Some <:ctyp< unit >>

let outbound_types _loc automata =
  G.fold_vertex
    (fun stage acc ->

       let edges =
         G.fold_succ_e
           (fun edge acc ->
              match G.E.label edge with
                <:ctyp< _ >> -> acc
              | <:ctyp< `Message of int >> -> acc
              | _ as edge -> edge :: acc)
           automata
           stage
           []
       in
       let t = <:ctyp< [= $list:edges$ ] >> in

       <:str_item<
         $acc$ ;
         type $lid:"outbound_" ^ Vertex.lident stage$ = $t$ ;
       >>)
    automata
    <:str_item< open Bin_prot.Std >>

let inbound_serializers _loc automata =
  G.fold_vertex
    (fun stage acc ->
       (* we look at all the successors of this stage *)
       match extract_inbound_type _loc automata stage with
         None ->
         Printf.eprintf "warning: stage %s isn't reachable, we can't infer the type\n" (Vertex.lident stage) ;
         acc
       | Some t ->

         let tp = TyDcl(_loc, Printf.sprintf "inbound_%s" (Vertex.lident stage), [], t, []) in

         let bin_size = Pa_bin_prot2.Generate_bin_size.bin_size false tp in
         let bin_write = Pa_bin_prot2.Generate_bin_write.bin_write false tp  in
         let bin_read = Pa_bin_prot2.Generate_bin_read.bin_read false tp in
         let type_class = Pa_bin_prot2.Generate_tp_class.bin_tp_class false tp in

         <:str_item<
              $acc$ ;
              $bin_size$ ;
              $bin_write$;
              $bin_read$;
              $type_class$;

              value $lid:"serialize_" ^ Vertex.lident stage$ v =
                 let size = $lid:"bin_size_inbound_" ^ Vertex.lident stage$ v in
                 let buf = Bin_prot.Common.create_buf size in
                 let s = Bytes.create size in
                 do {
                   ignore ($lid:"bin_write_inbound_" ^ Vertex.lident stage$ buf v ~pos:0) ;
                   Bin_prot.Common.blit_buf_string buf s size ;
                   s
                 } ;

              value $lid:"deserialize_" ^ Vertex.lident stage$ data =
                 let len = String.length data in
                 let buf = Bin_prot.Common.create_buf len in
                 do {
                   Bin_prot.Common.blit_string_buf data buf ~len;
                   $lid:"bin_read_inbound_" ^ Vertex.lident stage$ buf ~pos_ref:(ref 0)
                 } ;

             >>
    )
    automata
    <:str_item< open Bin_prot.Std >>

let outbound_dispatcher allow_none _loc automata stage schedule =
  G.fold_succ_e
    (fun edge acc ->
       let dest = Vertex.lident (G.E.dst edge) in
       match G.E.label edge with
       | <:ctyp< `Message of int >> -> acc (* messages transitions can't be emitted from the stage itself *)
       | <:ctyp< `$uid:constr$ >> ->
          if allow_none then
           <:match_case< `$uid:constr$ ->
                                   let args = $lid:"serialize_" ^ dest$ () in
                                   Some Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ }) >> :: acc
         else
           <:match_case< `$uid:constr$ ->
                                   let args = $lid:"serialize_" ^ dest$ () in
                                   Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ }) >> :: acc
       | <:ctyp< `$uid:constr$ of $args$ >> ->
         if allow_none then
           <:match_case< `$uid:constr$ args ->
                                   let args = $lid:"serialize_" ^ dest$ args in
                                   Some Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ }) >> :: acc
         else
           <:match_case< `$uid:constr$ args ->
                                   let args = $lid:"serialize_" ^ dest$ args in
                                   Ys_executor.({ stage = $str:dest$ ; args ; schedule = $schedule$ }) >> :: acc
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
         let _loc = Loc.mk (Loc.file_name _loc ^ ": " ^ Vertex.lident stage) in
         let dispatcher = outbound_dispatcher true _loc automata stage <:expr< Immediate >> in

         <:str_item<
           $acc$ ;
           value $lid:"step_" ^ Vertex.lident stage$ context args_serialized =
              Lwt.catch
                 (fun () ->
                    do {
                       context.log_info "calling stage %s" $str:Vertex.lident stage$ ;
                       let args = $lid:"deserialize_" ^ Vertex.lident stage$ args_serialized in
                       Lwt.bind
                          ($lid:Vertex.lident stage$ context args)
                          (fun r -> Lwt.return (match r with [ $list:dispatcher$ ])) })
                 (fun exn ->
                    do {
                       context.log_error ~exn "exception caught in stage %s: %s" $str:Vertex.lident stage$ (Printexc.to_string exn) ;
                       Lwt.return_none })

         >>)
    automata
    <:str_item< >>

let dispatch _loc automata =
  let cases =
    G.fold_vertex
      (fun stage acc ->
         match extract_inbound_type _loc automata stage with
           None -> acc
         | Some _ ->
           let dispatcher = outbound_dispatcher false _loc automata stage <:expr< Delayed timeout >> in
           let next_mailbox =
             G.fold_succ_e
               (fun edge acc ->
                  match G.E.label edge with
                  <:ctyp< `Message of int >> -> <:expr< Some $str:Vertex.lident (G.E.dst edge)$ >>
                  | _ -> acc)
               automata
               stage
               <:expr< None >>
           in

           <:match_case< $str:Vertex.lident stage$ ->

                        let module Stage_Specifics =
                          struct
                            value stage = $str:Vertex.lident stage$ ;
                            type outbound = $lid:"outbound_"^ Vertex.lident stage$ ;
                            value next_mailbox = $next_mailbox$ ;
                            value outbound_dispatcher timeout = fun [ $list:dispatcher$ ] ;
                          end in

                        let module Context = Factory(Stage_Specifics) in

                        let context = Context.context in

                        $lid:"step_" ^ Vertex.lident stage$ context call.Ys_executor.args >> :: acc
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
         match List.mem (`Tickable) (snd stage) with
           true -> `Unit
         | false -> `Unknown in
       let input_type =
         G.fold_pred_e
           (fun transition acc ->
              match G.E.label transition with
              | <:ctyp< `$uid:constr$ >> -> `Unit
              | <:ctyp< `$uid:constr$ of int >> -> `Int
              | <:ctyp< `$uid:constr$ of float >> -> `Float
              | <:ctyp< `$uid:constr$ of string >> -> `String
              | _ -> `Unknown)
           automata
           stage
           default in
       let stage = Vertex.lident stage in
       match input_type with
       | `Unknown -> acc
       | `Unit -> <:expr< [ (`Unit, $str:stage$) :: $acc$ ] >>
       | `Int -> <:expr< [ (`Int, $str:stage$) :: $acc$ ] >>
       | `Float -> <:expr< [ (`Float, $str:stage$) :: $acc$ ] >>
       | `String -> <:expr< [ (`String, $str:stage$) :: $acc$ ] >>)
    automata
    <:expr< [] >>

let mailables _loc automata =
  let stages = G.fold_vertex
      (fun stage acc ->
         let is_mailable = G.fold_pred_e
             (fun transition acc ->
                match G.E.label transition with
                  <:ctyp< `Message of int >> -> true
                | _ -> acc)
             automata
             stage
             false
         in
         if is_mailable then
           Vertex.lident stage :: acc
         else acc)
      automata
      [] in

  List.fold_left
    (fun acc s -> <:expr< [ $str:s$ :: $acc$ ] >>)
    <:expr< [] >>
    stages

(* we need to keep track of the next mailbox outside of the context for the sandbox *)
let mailing_helper _loc automata =
   let stages = G.fold_vertex
      (fun stage acc ->
        G.fold_pred_e
          (fun transition acc ->
             match G.E.label transition with
               <:ctyp< `Message of int >> -> (Vertex.lident (G.E.src transition), Vertex.lident stage) :: acc
             | _ -> acc)
          automata
          stage
          acc)
      automata
      [] in

  List.fold_left
    (fun acc (src, dst) -> <:expr< [ ($str:src$, $str:dst$) :: $acc$ ] >>)
    <:expr< [] >>
    stages

module Dot = Graph.Graphviz.Dot(struct

    include G

    let edge_attributes edge =
      match E.label edge with
      | ctyp -> [ `Label (Edge.to_string ctyp) ; `Arrowhead `Normal ; `Color 4711 ]


    let default_edge_attributes _ = []
    let get_subgraph _ = None
    let vertex_attributes v = [ `Shape `Ellipse ; `HtmlLabel (Vertex.lident v) ]
    let vertex_name v = Vertex.lident v
    let default_vertex_attributes _ = []
    let graph_attributes _ = [ `Margin 0.0 ]
  end)

let graph_to_string graph =
  let buffer = Buffer.create 1024 in
  let formatter = Format.formatter_of_buffer buffer in
  Dot.fprint_graph formatter graph;
  Format.pp_print_flush formatter () ;
  Buffer.contents buffer
