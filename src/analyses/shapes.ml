(** Shape analysis for cyclic doubly linked lists. *)

open Prelude.Ana
open Analyses

open ShapeDomain
open RegionDomain

module GU = Goblintutil
module Re = Region.Spec

module Spec =
struct
  include Analyses.DefaultSpec

  let name () = "shape"
  module LD = ShapeDomain.Dom
  module D  = Lattice.Prod (LD) (Re.D)
  module C  = Lattice.Prod (LD) (Re.D)
  module G  = Lattice.Prod (IntDomain.Booleans) (Re.G)

  let rec tryReallyHard ask gl upd f st =
    if LD.is_empty st then raise Deadcode else
      try f st
      with PleaseMaterialize k ->
        let st = LD.union
            (LD.map (SHMap.add' k (empty_list k   )) st)
            (LD.map (SHMap.add' k (nonempty_list k)) st)
        in
        assert (LD.for_all (fun sm -> SHMap.mem k sm) st);
        tryReallyHard ask gl upd f st
         | PleaseKillMe k -> raise Deadcode


  let vars e =
    let module S = Set.Make (Var) in
    let rec offs_contains o =
      match o with
      | NoOffset -> S.empty
      | Field (_,o) -> offs_contains o
      | Index (e,o) -> S.union (cv e) (offs_contains o)
    and cv e =
      match e with
      | SizeOf _
      | SizeOfE _
      | SizeOfStr _
      | AlignOf _
      | Const _
      | AlignOfE _ -> S.empty
      | UnOp  (_,e,_)     -> cv e
      | BinOp (_,e1,e2,_) -> S.union (cv e1) (cv e2)
      | AddrOf  (Mem e,o)
      | StartOf (Mem e,o)
      | Lval    (Mem e,o) -> S.union (cv e) (offs_contains o)
      | CastE (_,e)           -> cv e
      | Lval    (Var v2,o) -> S.add v2 (offs_contains o)
      | AddrOf  (Var v2,o)
      | StartOf (Var v2,o) -> S.add v2 (offs_contains o)
      | Question _ -> failwith "Logical operations should be compiled away by CIL."
      | _ -> failwith "Unmatched pattern."
    in
    S.elements (cv e)

  let re_context (ctx: (D.t,G.t,C.t) ctx) (re:Re.D.t): (Re.D.t, Re.G.t,C.t) ctx =
    let ge v = let a,b = ctx.global v in b in
    let spawn f v x = f v x in
    let geffect f v d = f v (false, d) in
    let split f d es = f (LD.singleton (SHMap.top ()), d) es in
    set_st_gl ctx re ge spawn geffect split

  let threadenter ctx lval f args =
    let st, re = ctx.local in
    Re.threadenter (re_context ctx re) lval f args |> List.map (fun d -> (LD.singleton (SHMap.top ()), d))
  let threadspawn ctx lval f args fctx = ctx.local

  let sync_ld ask gl upd st =
    let f sm (st, ds, rm, part)=
      let (nsm,nds,rmd) = sync_one ask gl upd sm in
      let add_regmap (ls,gs) (rm,part) =
        let set =
          if List.length gs = 0 then RS.singleton VFB.bullet else
            List.fold_right (fun x -> RS.add (VFB.of_vf (x,[]))) gs (RS.empty ())
        in
        let write_map l rm =
          RegMap.add (l,[]) set rm
        in
        RegMap.join rm (List.fold_right write_map ls (RegMap.bot ())),
        RegPart.join part (RegPart.singleton set)
      in
      let nrm, part = List.fold_right add_regmap rmd (rm,part) in
      let rc = List.map (fun (_,x) -> x) rmd in
      let part2 = List.fold_right (fun x xs -> RegPart.join xs (RegPart.singleton (List.fold_left (fun xs x -> RS.add (VFB.of_vf (x,[])) xs) (RS.empty ()) x))) rc part in
      (LD.add nsm st, nds@ds,nrm, part2)
    in
    LD.fold f st (LD.empty (), [], RegMap.bot (), RegPart.bot ())

  let reclaimLostRegions alive ctx (e,_) v =
    if (not e.vglob) &&  (not (Usedef.VS.mem e alive)) then () else
      let is_public = function
        | `Left (v,_) -> (not (is_private (Analyses.ask_of_ctx ctx) (`Left v)))
        | `Right _    -> false
      in
      let rs = RS.filter is_public v in
      (*    if RS.cardinal rs >= 2 then  Messages.waitWhat (e.vname^": "^RS.short 80 rs);*)
      if not (RS.is_empty rs) then ctx.sideg (Re.partition_varinfo ()) (false, RegPart.singleton rs)



  let sync ctx reason : D.t =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = ctx.sideg v (d,Re.G.bot ()) in
    let nst, dst, rm, part = tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (sync_ld (Analyses.ask_of_ctx ctx) gl upd) st in
    let nre = Re.sync (re_context ctx re) reason in
    let update k v m =
      let old = try RegMap.find k m with Not_found -> RS.empty () in
      if (not (RS.is_top old)) && RS.for_all (function  (`Left (v,_)) -> not (gl v) |  `Right _ -> true)  old
      then RegMap.add k v m
      else ((*ctx.sideg (Re.partition_varinfo ()) (false, RegPart.singleton v);*) m)
    in
    let nre =
      match nre with
      | `Lifted m -> `Lifted (RegMap.fold update rm m)
      | x -> x
    in
    let _ =
      match nre with
      | `Lifted m ->
        let alive =
          match MyLiveness.getLiveSet !Cilfacade.current_statement.sid with
          | Some x -> x
          | _      -> Usedef.VS.empty
        in
        RegMap.iter (reclaimLostRegions alive ctx) m
      | x -> ()
    in
    ctx.sideg (Re.partition_varinfo ()) (false, part);
    (* let is_public (v,_) = gl v in *)
    List.iter (uncurry ctx.sideg) (List.map (fun (v,d) -> (v,(d, Re.G.bot ()))) dst);
    (nst,nre)

  (* transfer functions *)
  let assign_ld ask gl dup (lval:lval) (rval:exp) st : LD.t =
    match eval_lp ask (Lval lval), eval_lp ask rval, rval with
    | Some (l,`Next), Some (r,`NA),_ -> LD.map (normal ask gl dup l `Next r) st
    | Some (l,`Prev), Some (r,`NA),_ -> LD.map (normal ask gl dup l `Prev r) st
    | Some (l,`NA)  , Some (r,dir),_ ->
      LD.fold (fun d xs -> List.fold_right LD.add (add_alias ask gl dup l (r,dir) d) xs) st (LD.empty ())
    | Some (l,`Next)  , _, c when isZero c ->
      LD.map (write_null ask gl dup l `Next) st
    | Some (l,`Prev)  , _, c when isZero c ->
      LD.map (write_null ask gl dup l `Prev) st
    | _ ->
      let ls = vars (Lval lval) in
      LD.map (kill_vars ask gl dup ls) st


  let assign ctx (lval:lval) (rval:exp) : D.t =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = ctx.sideg v (d,Re.G.bot ()) in
    tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (assign_ld (Analyses.ask_of_ctx ctx) gl upd lval rval) st,
    Re.assign (re_context ctx re) lval rval

  let invariant ask gl lp1 lp2 st b =
    let xor x y = if x then not y else y in
    let inv_one (sm:SHMap.t) (xs:LD.t) =
      if xor b (must_alias ask gl lp1 lp2 sm)
      then LD.add sm xs
      else xs
    in
    LD.fold inv_one st (LD.empty ())


  let branch_ld ask gl st (exp:exp) (tv:bool) : LD.t =
    let xor x y = if x then not y else y in
    let eval_lps e1 e2 b =
      match eval_lp ask e1, eval_lp ask e2 with
      | Some lpe1, Some lpe2 -> invariant ask gl lpe1 lpe2 st (xor tv b)
      | _ -> st
    in
    match stripCasts exp with
    | BinOp (Ne,e1,e2,_) -> eval_lps (stripCasts e1) (stripCasts e2) false
    | BinOp (Eq,e1,e2,_) -> eval_lps (stripCasts e1) (stripCasts e2) true
    | _ -> st

  let branch ctx exp tv : D.t =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = ctx.sideg v (d,Re.G.bot ()) in
    tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (fun st -> branch_ld (Analyses.ask_of_ctx ctx) gl st exp tv) st,
    Re.branch (re_context ctx re) exp tv

  let body ctx (f:fundec) : D.t =
    let st, re = ctx.local in
    MyLiveness.computeLiveness f;
    st, Re.body (re_context ctx re) f

  let return_ld ask gl dup st (exp:exp option) (f:fundec) : LD.t =
    LD.map (kill_vars ask gl dup (f.sformals @ f.slocals)) st

  let return ctx exp f : D.t =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = ctx.sideg v (d,Re.G.bot ()) in
    tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (fun st -> return_ld (Analyses.ask_of_ctx ctx) gl upd st exp f) st,
    Re.return (re_context ctx re) exp f

  let enter_func_ld ask gl dup (lval: lval option) (fd:fundec) (args:exp list) st : LD.t =
    let rec zip xs ys =
      match xs, ys with
      | x::xs, y::ys -> (x, y) :: zip xs ys
      | _ -> []
    in
    let asg (v,e) d = assign_ld ask gl dup (Var v,NoOffset) e d in
    List.fold_right asg (zip fd.sformals args) st

  let enter ctx lval f args =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = () in
    let es = tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (enter_func_ld (Analyses.ask_of_ctx ctx) gl upd lval f args) st  in
    let es' = Re.enter (re_context ctx re) lval f args in
    List.map (fun (x,y) -> (st,x),(es,y)) es'

  let combine ctx (lval:lval option) fexp (f:fundec) (args:exp list) fc (au:D.t) : D.t =
    au

  let special_fn_ld ask gl dup (lval: lval option) (f:varinfo) (arglist:exp list) st  =
    let lift_st x = [x,integer 1, true] in
    match f.vname, arglist, lval with
    | "kill", [ee], _ -> begin
        match eval_lp ask ee with
        | Some (lp, _) -> lift_st (LD.map (kill ask gl dup lp) st)
        | _ -> lift_st st
      end
    | "collapse", [e1;e2], _ -> begin
        match eval_lp ask e1, eval_lp ask e2 with
        | Some (lp1, _), Some (lp2, _) -> lift_st (LD.map (collapse_summary ask gl dup lp1 lp2) st)
        | _ -> lift_st st
      end
    | "list_empty", [e], Some lv ->
      begin match eval_lp ask (stripCasts e) with
        | Some (lp, `NA) ->
          let branch = invariant ask gl (lp,`NA) (lp,`Next) st in
          let s1 = branch true in
          let s2 = branch false in
          if LD.is_empty s1 then [s2, Lval lv, true] else
          if LD.is_empty s2 then [s1, Lval lv, false] else
            [ branch true , Lval lv, false
            ; branch false, Lval lv, true ]
        | _ -> lift_st st
      end
    | _ ->
      match lval with
      | None -> lift_st st
      | Some x ->
        let ls = vars (Lval x) in
        lift_st (LD.map (kill_vars ask gl dup ls) st)

  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    let st, re = ctx.local in
    let gl v = let a,b = ctx.global v in a in
    let upd v d = ctx.sideg v (d,Re.G.bot ()) in
    let s1 = tryReallyHard (Analyses.ask_of_ctx ctx) gl upd (special_fn_ld (Analyses.ask_of_ctx ctx) gl upd lval f arglist) st in
    let s2 = Re.special (re_context ctx re) lval f arglist in
    List.iter (fun (x,y,z) -> ctx.split (x,s2) [Events.SplitBranch (y, z)]) s1;
    raise Analyses.Deadcode

  let query ctx (type a) (q: a Queries.t) =
    let st, re = ctx.local in
    Re.query (re_context ctx re) q

  let startstate v = LD.singleton (SHMap.top ()), Re.startstate v
  let exitstate  v = LD.singleton (SHMap.top ()), Re.exitstate v

  let init marshal = Printexc.record_backtrace true

  (*  let init () = *)
  (*    Goblintutil.region_offsets := false*)
end

let _ =
  MCP.register_analysis (module Spec : MCPSpec)
