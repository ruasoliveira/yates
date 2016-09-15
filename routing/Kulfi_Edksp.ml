open Frenetic_Network
open Net
open Core.Std
open Kulfi_Globals
open Kulfi_LP_Lang
open Kulfi_Routing_Util
open Kulfi_Types

let () = match !Kulfi_Globals.rand_seed with
  | Some x -> Random.init x
  | None -> Random.self_init ~allow_in_tests:true ()

let objective = Var "Z"

let capacity_constraints (topo : Topology.t) (src : Topology.vertex) (dst : Topology.vertex)
                         (init_acc : constrain list) : constrain list =
  (* For every inter-switch edge, there is a unit capacity constraint *)
  Topology.fold_edges
    (fun edge acc ->
    if edge_connects_switches edge topo then
      let flow_on_edge = Var(var_name topo edge (src,dst)) in
      (* Total flow is at most 1 *)
      let name = Printf.sprintf "cap_%s"
          (string_of_edge topo edge) in
      (Leq (name, flow_on_edge, 1.))::acc
    else acc) topo init_acc

let num_path_constraints (topo : Topology.t) (src : Topology.vertex) (dst : Topology.vertex) (k:int)
    (init_acc : constrain list) : constrain list =
  (* Constraint: sum of out going flows to other switches from src's ingress switch = k  *)
  let ingress_switch = neighboring_edges topo src
    |> List.hd_exn
    |> Topology.edge_dst
    |> fst in
  let edges = neighboring_edges topo ingress_switch in
  let diffs = List.fold_left edges ~init:[] ~f:(fun acc edge ->
    if edge_connects_switches edge topo then
          let forward_amt = var_name topo edge (src,dst) in
          let reverse_amt = var_name_rev topo edge (src,dst) in
          let net_outgoing = minus (Var (forward_amt)) (Var (reverse_amt)) in
          net_outgoing::acc
    else acc) in
  let sum_net_outgoing = Sum (diffs) in
  let name = Printf.sprintf "num-%s-%s" (name_of_vertex topo src) (name_of_vertex topo dst) in
  (Eq (name, sum_net_outgoing, Float.of_int k))::init_acc

let conservation_constraints_st (topo : Topology.t) (src : Topology.vertex) (dst : Topology.vertex)
    (init_acc : constrain list) : constrain list =
  (* Every node in the topology except the source and sink has conservation constraints *)
  Topology.fold_vertexes (fun v acc ->
   if v = src || v = dst then acc else
      let edges = neighboring_edges topo v in
      let outgoing = List.fold_left edges ~init:[] ~f:(fun acc_vars e ->
        (Var (var_name topo e (src,dst)))::acc_vars) in
      let incoming = List.fold_left edges ~init:[] ~f:(fun acc_vars e ->
        (Var (var_name_rev topo e (src,dst)))::acc_vars) in
      let total_out = Sum (outgoing) in
      let total_in = Sum (incoming) in
      let net = minus total_out total_in in
      let name = Printf.sprintf "con-%s-%s_%s" (name_of_vertex topo src)
        (name_of_vertex topo dst) (name_of_vertex topo v) in
      let constr = Eq (name, net, 0.) in
      constr::acc) topo init_acc

let minimize_path_lengths (topo : Topology.t) (src : Topology.vertex) (dst : Topology.vertex)
    (init_acc : constrain list) : constrain list =
  (* Set objective = sum of all path lengths *)
  let paths_list = Topology.fold_edges (fun e acc ->
    (Var (var_name topo e (src,dst)))::acc) topo [] in
  let total_path_length = Sum (paths_list) in
  let path_length_obj = minus total_path_length objective in
  let name = Printf.sprintf "obj-%s-%s" (name_of_vertex topo src)
      (name_of_vertex topo dst) in
  let constr = Eq (name, path_length_obj, 0.) in
  constr::init_acc

let lp_of_st (topo : Topology.t) (src : Topology.vertex) (dst : Topology.vertex) (k : int) =
  let all_constrs = capacity_constraints topo src dst []
    |> num_path_constraints topo src dst k
    |> conservation_constraints_st topo src dst
    |> minimize_path_lengths topo src dst in
  (objective, all_constrs)

let rec new_rand () : float =
  let rand = (Random.float 1.0) in
  let try_fn = (Printf.sprintf "lp/edksp_%f.lp" rand) in
  match Sys.file_exists try_fn with
      `Yes -> new_rand ()
       | _ -> rand

(* Given a topology and a set of pairs with demands,
 *  returns k edge-disjoint shortest paths per src-dst pair
 * TODO: handle case where k edge-disjoint shortest paths are not possible,
 * currently it returns empty path list for such a pair *)
let solve (topo:topology) (pairs:demands) : scheme =
  SrcDstMap.fold pairs ~init:SrcDstMap.empty ~f:(fun ~key:(src, dst) ~data:_ acc ->
  (* Iterate over each src-dst pair to find k edge-disjoint shortest paths *)
  let name_table = Hashtbl.Poly.create () in
  Topology.iter_vertexes (fun vert ->
    let label = Topology.vertex_to_label topo vert in
    let name = Node.name label in
        Hashtbl.Poly.add_exn name_table name vert) topo;

  let lp = lp_of_st topo src dst (!Kulfi_Globals.budget) in
  let rand = new_rand () in
  let lp_filename = (Printf.sprintf "lp/edksp_%f.lp" rand) in
  let lp_solname = (Printf.sprintf "lp/edksp_%f.sol" rand) in
  serialize_lp lp lp_filename;

  let method_str = (Int.to_string !gurobi_method) in
  let gurobi_in = Unix.open_process_in
    ("gurobi_cl Method=" ^ method_str ^ " OptimalityTol=1e-9 ResultFile=" ^ lp_solname ^ " " ^ lp_filename) in
  let time_str = "Solved in [0-9]+ iterations and \\([0-9.e+-]+\\) seconds" in
  let time_regex = Str.regexp time_str in
  let rec read_output gurobi solve_time =
    try
      let line = input_line gurobi in
      if Str.string_match time_regex line 0 then
        let num_seconds = Float.of_string (Str.matched_group 1 line) in
          read_output gurobi num_seconds
        else
          read_output gurobi solve_time
      with
        End_of_file -> solve_time in
    let _ = read_output gurobi_in 0. in
    ignore (Unix.close_process_in gurobi_in);

    (* read back all the edge flows from the .sol file *)
    let read_results input =
      let results = open_in input in
      let result_str = "^f_\\([a-zA-Z0-9]+\\)--\\([a-zA-Z0-9]+\\)_" ^
                       "\\([a-zA-Z0-9]+\\)--\\([a-zA-Z0-9]+\\) \\([0-9.e+-]+\\)$"
      in
      let regex = Str.regexp result_str in
      let rec read inp opt_z flows =
        let line = try input_line inp
          with End_of_file -> "" in
        if line = "" then (opt_z,flows)
        else
          let new_z, new_flows =
            if line.[0] = '#' then (opt_z, flows)
            else if line.[0] = 'Z' then
              let ratio_str = Str.string_after line 2 in
              let ratio = Float.of_string ratio_str in
              (ratio *. demand_divisor /. cap_divisor, flows)
            else
              (if Str.string_match regex line 0 then
                 let vertex s = Topology.vertex_to_label topo
                     (Hashtbl.Poly.find_exn name_table s) in
                 let dem_src = vertex (Str.matched_group 1 line) in
                 let dem_dst = vertex (Str.matched_group 2 line) in
                 let edge_src = vertex (Str.matched_group 3 line) in
                 let edge_dst = vertex (Str.matched_group 4 line) in
                 let flow_amt = Float.of_string (Str.matched_group 5 line) in
                 if flow_amt = 0. then (opt_z, flows)
                 else
                   let tup = (dem_src, dem_dst, flow_amt, edge_src, edge_dst) in
                   (opt_z, (tup::flows))
               else (opt_z, flows)) in
          read inp new_z new_flows in
          (* end read *)
      let result = read results 0. [] in
      In_channel.close results; result in
    (* end read_results *)
    let ratio, flows = read_results lp_solname in
    let _ = Sys.remove lp_filename in
    let _ = Sys.remove lp_solname in
    let flows_table = Hashtbl.Poly.create () in

    (* partition the edge flows based on which commodity they are *)
    List.iter flows ~f:(fun (d_src, d_dst, flow, e_src, e_dst) ->
        if Hashtbl.Poly.mem flows_table (d_src, d_dst) then
          let prev_edges = Hashtbl.Poly.find_exn flows_table (d_src, d_dst) in
          Hashtbl.Poly.set flows_table (d_src, d_dst)
            ((e_src, e_dst, flow)::prev_edges)
        else
          Hashtbl.Poly.add_exn flows_table (d_src, d_dst)
            [(e_src, e_dst, flow)]);

    let tmp_scheme = Kulfi_Mcf.recover_paths topo flows_table in
    let st_ppmap = SrcDstMap.find tmp_scheme (src,dst) in
    match st_ppmap with
    | None -> acc
    | Some x ->
        SrcDstMap.add ~key:(src,dst) ~data:x acc)


let initialize _ = ()

let local_recovery = Kulfi_Types.normalization_recovery