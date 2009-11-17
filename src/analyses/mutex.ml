module A = Analyses
module M = Messages
module GU = Goblintutil
module Addr = ValueDomain.Addr
module Offs = ValueDomain.Offs
module Lockset = LockDomain.Lockset
module AD = ValueDomain.AD
module ID = ValueDomain.ID
module LockingPattern = Exp.LockingPattern
module Exp = Exp.Exp
(*module BS = Base.Spec*)
module BS = Base.Main
module LF = LibraryFunctions
open Cil
open Pretty

(** only report write races *)
let no_read = ref false
(** Truns off field-sensitivity. *)
let field_insensitive = ref false
(** Avoids the merging of fields, not really sound *)
let unmerged_fields = ref false
(** Take the possible failing of standard locking operations into account. *)
let failing_locks = ref false

(* Some helper functions ... *)
let is_atomic_type (t: typ): bool = match t with
  | TNamed (info, attr) -> info.tname = "atomic_t"
  | _ -> false

let is_atomic lval = 
  let (lval, _) = removeOffsetLval lval in
  let typ = typeOfLval lval in
    is_atomic_type typ

let is_ignorable lval = 
  Base.is_mutex_type (typeOfLval lval) || is_atomic lval


(** Data race analyzer without base --- this is the new standard *)  
module NoBaseSpec =
struct  

  (** name for the analysis (btw, it's "Only Mutex Must") *)
  let name = "Only Mutex Must"

  (** a strange function *)
  let es_to_string f es = f.svar.vname
  
  (** no init. needed -- call [BS.init] *)
  let init () = () 

  (** Add current lockset alongside to the base analysis domain. Global data is collected using dirty side-effecting. *)
  module Dom = Lockset
  
  (** We do not add global state, so just lift from [BS]*)
  module Glob = Global.Make (Lattice.Unit)
  
  let get_diff _ = []
  let reset_diff x = x
  
  (* NB! Currently we care only about concrete indexes. Base (seeing only a int domain
     element) answers with the string "unknown" on all non-concrete cases. *)
  let rec conv_offset x =
    match x with
      | `NoOffset    -> `NoOffset
      | `Index (Const (CInt64 (i,_,_)),o) -> `Index (ValueDomain.ID.of_int i, conv_offset o)
      | `Index (_,o) -> `Index (ValueDomain.ID.top (), conv_offset o)
      | `Field (f,o) -> `Field (f, conv_offset o)

  let rec conv_const_offset x =
    match x with
      | Cil.NoOffset    -> `NoOffset
      | Cil.Index (Const (CInt64 (i,_,_)),o) -> `Index (ValueDomain.ID.of_int i, conv_const_offset o)
      | Cil.Index (_,o) -> `Index (ValueDomain.ID.top (), conv_const_offset o)
      | Cil.Field (f,o) -> `Field (f, conv_const_offset o)

  let rec replace_elem (v,o) q ex =
    match ex with
      | Cil.AddrOf  (Cil.Mem e,_) when e == q ->v, Offs.from_offset (conv_offset o)
      | Cil.StartOf (Cil.Mem e,_) when e == q ->v, Offs.from_offset (conv_offset o)
      | Cil.Lval    (Cil.Mem e,_) when e == q ->v, Offs.from_offset (conv_offset o)
      | Cil.CastE (_,e)           -> replace_elem (v,o) q e
      | _ -> v, Offs.from_offset (conv_offset o)
  
  (** queries *)
  let query _ _ (x:Dom.t) (q:Queries.t) : Queries.Result.t = Queries.Result.top ()

  type access = Concrete of (exp option * Cil.varinfo * Offs.t * bool)
              | Region   of (exp option * Cil.varinfo * Offs.t * bool) 
              | Unknown  of (exp * bool)
  type accesses = access list

  let unknown_access () =
    M.warn "Access to unknown address could be global"
  
  let access_address ask regs write lv : accesses =
    match ask (Queries.MayPointTo (mkAddrOf lv)) with
      | `LvalSet a when not (Queries.LS.is_top a) -> 
          let to_accs (v,o) xs = 
            Concrete (Some (Lval lv), v, Offs.from_offset (conv_offset o), write) :: xs  
          in
          Queries.LS.fold to_accs a []
      | _ ->         
          let add_reg (v,o) = 
            Region (Some (Lval lv), v, Offs.from_offset (conv_offset o), write)
          in 
          if List.length regs = 0 
          then [Unknown (Lval lv,write)]
          else List.map add_reg regs

  let rec access_one_byval a rw (exp:Cil.exp): accesses  = 
    let accs regs = 
      match exp with 
        (* Integer literals *)
        | Cil.Const _ -> []
        (* Variables and address expressions *)
        | Cil.Lval lval -> 
          let a1 = access_address a regs rw lval in
          let a2 = access_lv_byval a lval in
            a1 @ a2
        (* Binary operators *)
        | Cil.BinOp (op,arg1,arg2,typ) -> 
            let a1 = access_one_byval a rw arg1 in
            let a2 = access_one_byval a rw arg2 in
              a1 @ a2
        (* Unary operators *)
        | Cil.UnOp (op,arg1,typ) -> access_one_byval a rw arg1
        (* The address operators, we just check the accesses under them *)
        | Cil.AddrOf lval -> access_lv_byval a lval
        | Cil.StartOf lval -> access_lv_byval a lval
        (* Most casts are currently just ignored, that's probably not a good idea! *)
        | Cil.CastE  (t, exp) -> access_one_byval a rw exp
        | _ -> []
    in
    let is_unknown x = match x with Unknown _ -> true | _ -> false in
    match a (Queries.Regions exp) with
      | `Bot -> 
(*          Messages.report ((sprint 80 (d_exp () exp))^" is thread local");*)
          List.filter is_unknown (accs [])
      | `LvalSet regs -> 
(*          Messages.report ((sprint 80 (d_exp () exp))^" is in regions "^Queries.LS.short 800 regs);*)
          accs (Queries.LS.elements regs)
      | _ -> accs []
  (* Accesses during the evaluation of an lval, not the lval itself! *)
  and access_lv_byval a (lval:Cil.lval): accesses = 
    let rec access_offset (ofs: Cil.offset): accesses = 
      match ofs with 
        | Cil.NoOffset -> []
        | Cil.Field (fld, ofs) -> access_offset ofs
        | Cil.Index (exp, ofs) -> 
          let a1 = access_one_byval a false exp in
          let a2 = access_offset ofs in
            a1 @ a2
    in 
      match lval with 
        | Cil.Var x, ofs -> access_offset ofs
        | Cil.Mem n, ofs -> 
          let a1 = access_one_byval a false n in
          let a2 = access_offset ofs in
            a1 @ a2

   let access_one_top = access_one_byval 

   let access_byval a (rw: bool) (exps: Cil.exp list): accesses =
     List.concat (List.map (access_one_top a rw) exps)

   let access_reachable ask (exps: Cil.exp list) = 
     (* Find the addresses reachable from some expression, and assume that these
      * can all be written to. *)
     let do_exp e = 
       match ask (Queries.ReachableFrom e) with
         | `LvalSet a when not (Queries.LS.is_top a) -> 
            let to_extra (v,o) xs = Concrete (None, v, Base.Offs.from_offset (conv_offset o), true) :: xs  in
            Queries.LS.fold to_extra a [] 
         (* Ignore soundness warnings, as invalidation proper will raise them. *)
         | _ -> []
     in
       List.concat (List.map do_exp exps)
  
  let eval_exp_addr a exp =
    let gather_addr (v,o) b = ValueDomain.Addr.from_var_offset (v,conv_offset o) :: b in
    match a (Queries.MayPointTo exp) with
      | `LvalSet a when not (Queries.LS.is_top a) -> 
          Queries.LS.fold gather_addr a []    
      | _ -> []
  
  let lock rw may_fail a lv arglist ls =
    let is_a_blob addr = 
      match LockDomain.Addr.to_var addr with
        | [a] -> a.vname.[0] = '(' 
        | _ -> false
    in  
    let nothing ls = [ls,Cil.integer 1,true] in
    let lock_one (e:LockDomain.Addr.t) =
      let set_ret tv sts = 
        match lv with 
          | None -> [sts,Cil.integer 1,true]
          | Some lv -> [sts,Lval lv,tv]
      in 
      if is_a_blob e then
        nothing ls
      else begin
        set_ret false  (Lockset.add (e,rw) ls) @
        if may_fail then set_ret true ls else []
      end
    in
      match arglist with
        | [x] -> begin match  (eval_exp_addr a x) with 
                          | [e]  -> lock_one e
                          | _ -> nothing ls 
                  end
        | _ -> nothing (Lockset.top ())

  (* [per_elementize oa op locks] takes offset of current access [oa],
     quantified access offset [op] and lockset and returns a quantified 
     lock lval *)
  let per_elementize oa op (locks:Dom.t) =
    let wildcard_ok ip il ia = ID.is_top ip && ID.equal ia il in
    let rec no_wildcards x =
      match x with
        | `NoOffset -> true
        | `Index (i,o) -> not (ID.is_top i) && no_wildcards o
        | `Field (_,o) -> no_wildcards o
    in
    let rec get_perel_lock_offs oa op ol =
      match oa, op, ol with
        | _, `NoOffset, _ -> ol
        | `Index (ia,oa), `Index (ip,op), `Index (il,ol) 
            when wildcard_ok ip il ia ->
            `Index (ip,get_perel_lock_offs oa op ol)            
        | `Index (ia,oa), `Index (ip,op), `Index (il,ol) 
            when not (ID.is_top ip) ->
            `Index (il,get_perel_lock_offs oa op ol)  
        | _, `Index (ip,op), _ 
            when no_wildcards ol ->
            ol
        | `Field (fa,oa), `Field (fp,op), `Field (fl,ol) ->
            `Field (fl,get_perel_lock_offs oa op ol)  
        | _, `Field (fp,op), _ 
            when no_wildcards ol ->
            ol
        | _ -> raise Not_found
    in
    let add_perel (lock,_) ls =
      match Addr.to_var_offset lock, Offs.to_offset oa, Offs.to_offset op with
        | [va,ol], [oa], [op] -> begin
          try (va, get_perel_lock_offs oa op ol) :: ls
          with Not_found -> ls end
        | _ -> ls
    in
      match Lockset.fold add_perel locks [] with
        | x :: _ -> Some x
        | _ -> None
  
  (* Type invariant variables. *)
  let type_inv_tbl = Hashtbl.create 13 
  let type_inv (c:compinfo) : Lval.CilLval.t list =
    try [Hashtbl.find type_inv_tbl c.ckey,`NoOffset]
    with Not_found ->
        let i = makeGlobalVar ("(struct "^c.cname^")") (TComp (c,[])) in
        Hashtbl.add type_inv_tbl c.ckey i;
        [i, `NoOffset]

  (* Try to find a suitable type invarinat --- and by that we mean a struct.
     We peel away field accesses, then take the type and put the fields back. *)
  let best_type_inv exs : Cil.exp option =
    let add_el es e : LockingPattern.ee list list = 
      try LockingPattern.toEl e :: es
      with LockingPattern.NotSimpleEnough -> es
    in
    let full_els = List.fold_left add_el [] exs in
    let el_os = List.map LockingPattern.strip_fields full_els in
(*     let dummy = Cil.integer 42 in *)
    let add_struct xs (e,fs) = 
      match fs with
        | LockingPattern.Field f :: _ -> (e,f.fcomp,fs) :: xs 
        | _ -> xs
(*      match unrollType (typeOf (LockingPattern.fromEl e dummy)) with
        | TComp (c,_) -> (e,c,fs) :: xs 
        | _ -> xs*)
    in
    try 
      let es, c, fs = List.hd (List.fold_left add_struct [] el_os) in
      let e_inv = type_inv c in
      let add_fields_back (v,o) = 
        LockingPattern.fromEl fs (Lval (Var v,NoOffset))
      in
      Some (add_fields_back (List.hd e_inv))
    with
      | LockingPattern.NotSimpleEnough -> None
      | Failure _ -> None
  
  (** Access counting is done using side-effect (accesses added in [add_accesses] and read in [finalize]) : *)
  
  (* 
    Access counting using side-effects: ('|->' is a hash-map)
    
    acc     : var |-> (loc, mt_flag, rw_falg, lockset, offset) set
    accKeys : var set
    
    Remark:
    As you can see, [accKeys] is just premature optimization, so we dont have to iterate over [acc] to get all keys.
   *)
  module Acc = Hashtbl.Make (Basetype.Variables)
  module AccKeySet = Set.Make (Basetype.Variables)
  module AccValSet = Set.Make (Printable.Prod3 (Printable.Prod3 (Basetype.ProgLines) (BS.Flag) (IntDomain.Booleans)) (Lockset) (Offs))
  let acc     : AccValSet.t Acc.t = Acc.create 100
  let accKeys : AccKeySet.t ref   = ref AccKeySet.empty 
  
  (* Just adds accesses. It says concrete, but we use it to add verified 
     non-concrete accesses too.*)
  let add_concrete_access fl loc ust (v, o, rv: Cil.varinfo * Offs.t * bool) =
    if (v.vglob) then
      let curr : AccValSet.t = try Acc.find acc v with _ -> AccValSet.empty in
      let neww : AccValSet.t = AccValSet.add ((loc,fl,rv),ust,o) curr in
      Acc.replace acc v neww;
      accKeys := AccKeySet.add v !accKeys
  
  (* Try to add symbolic locks --- returns [false] on failure.*)
  let rec add_per_element_access ask loc ust (e,rw:exp * bool) =
    let query_lv exp ci =
        match ask (Queries.MayPointTo exp), ci with
        | `LvalSet l, _ when not (Queries.LS.is_top l) -> Queries.LS.elements l
        | `Top, Some ci
        | `LvalSet _, Some ci-> type_inv ci
        | _ ->  unknown_access (); []
    in
    let rec offs_perel o =
      match o with
        | `Index (CastE (intType, Const (CStr "unknown")),o)
            -> `Index (Cil.kinteger64 IInt GU.inthack,offs_perel o)
        | `Index (i,o) -> `Index (i,offs_perel o)
        | `Field (f,o) -> `Field (f,offs_perel o) 
        | _ -> `NoOffset
    in
    let one_perelem (e,a,l) =
      let with_element (v,o) = 
        let accs = access_one_byval ask rw (Exp.replace_base (v,offs_perel o) e a) in
        let lock = 
          match Exp.fold_offs (Exp.replace_base (v,offs_perel o) e l) with
            | Some (v, o) -> Dom.ReverseAddrSet.add (LockDomain.Addr.from_var_offset (v,conv_const_offset o) ,true) ust
            | None -> ust
        in
        let no_recurse x =
          match x with
            | Concrete (_,v,o,rw) -> Concrete (None,v,o,rw)
            | x -> x
        in
        add_accesses ask (List.map no_recurse accs) lock
      in
      let b_comp = Exp.base_compinfo e a in
      List.iter with_element (query_lv e b_comp)
    in
    match ask (Queries.PerElementLock e) with
      | `PerElemLock a 
          when not (Queries.PS.is_top a || Queries.PS.is_empty a) 
          -> Queries.PS.iter one_perelem a;
             true
      | _ -> false
        
  (* All else must have failed --- making a last ditch effort to generate type 
      invariant if that fails then give up and become unsound. *)
  and add_type_access ask loc ust (e,rw:exp * bool) =
    let eqset =
      match ask (Queries.EqualSet e) with
        | `ExprSet es 
            when not (Queries.ES.is_bot es) 
            -> Queries.ES.elements es
        | _ -> [e]
    in
      match best_type_inv eqset with
        | None -> unknown_access ()
        | Some ti -> 
          let accs = access_one_byval ask rw (mkAddrOf (mkMem ti NoOffset)) in
          add_accesses ask accs ust
    
  (** Function [add_accesses accs st] fills the hash-map [acc] *)
  and add_accesses ask (accessed: accesses) (ust:Dom.t) = 
    if not !GU.may_narrow then
      let fl = 
        match ask Queries.SingleThreaded, ask Queries.CurrentThreadId with
          | `Int is_sing, _ when Queries.ID.to_bool is_sing = Some true -> BS.Flag.get_single ()
          | _,`Int x when  Queries.ID.to_int x = Some 1L -> BS.Flag.get_main ()
          | _ -> BS.Flag.get_multi ()
      in
      if BS.Flag.is_multi fl then
        let loc = !GU.current_loc in
        let dispatch ax =
          match ax with
            | Concrete (Some e,v,o,rw) -> 
                if   not (add_per_element_access ask loc ust (e,rw)) 
                then add_concrete_access fl loc ust (v,o,rw)
            | Concrete (None,v,o,rw) -> 
                add_concrete_access fl loc ust (v,o,rw)
            | Region (Some e,v,o,rw) -> 
                if   not (add_per_element_access ask loc ust (e,rw)) 
                then add_concrete_access fl loc ust (v,o,rw)
            | Region (None,v,o,rw) -> 
                add_concrete_access fl loc ust (v,o,rw)
            | Unknown a -> 
                if   not (add_per_element_access ask loc ust a) 
                then add_type_access ask loc ust a 
        in
          List.iter dispatch accessed
    
       
  (** First we consider reasonable joining states if locksets are equal, also we don't expect precision if base state is equal*)
  let should_join x y = true
  
  (** We just lift start state, global and dependecy functions: *)
  
  let startstate () = Lockset.empty ()
  let otherstate () = Lockset.empty ()
  
  
  (** Transfer functions: *)
  
  let assign a lval rval gs (ust: Dom.t) : Dom.t = 
    let b1 = access_one_top a true (Lval lval) in 
    let b2 = access_one_top a false rval in
    add_accesses a (b1@b2) ust;
    ust
    
  let branch a exp tv gs (ust: Dom.t) : Dom.t =
    let accessed = access_one_top a false exp in
    add_accesses a accessed ust;
    ust
    
  let return a exp fundec gs (ust: Dom.t) : Dom.t =
    begin match exp with 
      | Some exp -> 
          let accessed = access_one_top a false exp in
          add_accesses a accessed ust
      | None -> () 
    end;
    ust
        
  let body a f gs (ust: Dom.t) : Dom.t =  ust

  let eval_funvar a exp gs bl = 
    let read = access_one_top a false exp in
    add_accesses a read bl; 
    []
  
  
  let special_fn a lv f arglist gs (ls: Dom.t) : (Dom.t * exp * bool) list =
    let remove_rw x st = Lockset.remove (x,true) (Lockset.remove (x,false) st) in
    let unlock remove_fn =
      match arglist with
        | [x] -> begin match  (eval_exp_addr a x) with 
                        | [] -> [(Lockset.empty ()),Cil.integer 1, true]
                        | es -> [(List.fold_right remove_fn es ls), Cil.integer 1, true]
                end
        | _ -> [ls, Cil.integer 1, true]
    in
    match f.vname with
   (* | "sem_wait"*)
      | "_spin_trylock" | "_spin_trylock_irqsave" | "pthread_mutex_trylock" 
      | "pthread_rwlock_trywrlock"
          ->lock true true a lv arglist ls
      | "_spin_lock" | "_spin_lock_irqsave" | "_spin_lock_bh"
      | "mutex_lock" | "mutex_lock_interruptible" | "_write_lock"
      | "pthread_mutex_lock" | "pthread_rwlock_wrlock" | "GetResource"
          -> lock true !failing_locks a lv arglist ls
      | "pthread_rwlock_tryrdlock" | "pthread_rwlock_rdlock" | "_read_lock" 
          -> lock false !failing_locks a lv arglist ls
      | "__raw_read_unlock" | "__raw_write_unlock" -> 
          let drop_raw_lock x =
            let rec drop_offs o = 
              match o with
                | `Field ({fname="raw_lock"},`NoOffset) -> `NoOffset
                | `Field (f1,o1) -> `Field (f1, drop_offs o1)
                | `Index (i1,o1) -> `Index (i1, drop_offs o1)
                | `NoOffset -> `NoOffset
            in
            match Addr.to_var_offset x with
              | [(v,o)] -> Addr.from_var_offset (v, drop_offs o)
              | _ -> x
          in
          unlock (fun l -> remove_rw (drop_raw_lock l))
   (* | "sem_post"*)
      | "_spin_unlock" | "_spin_unlock_irqrestore" | "_spin_unlock_bh"
      | "mutex_unlock" | "ReleaseResource" 
      | "pthread_mutex_unlock" 
          -> unlock remove_rw
      | x -> 
          let arg_acc act = 
            match LF.get_invalidate_action x with
              | Some fnc -> (fnc act arglist) 
              | _ -> []
          in
          let r1 = access_byval a false (arg_acc `Read) in
          let a1 = access_reachable a   (arg_acc `Write) in
          add_accesses a (r1@a1) ls;
          [ls, Cil.integer 1, true]
          
  let enter_func a lv f args gs lst : (Dom.t * Dom.t) list =
    [(lst,lst)]

  let leave_func a lv f args gs bl al = 
    let read = access_byval a false args in
    add_accesses a read bl; 
    al
    
  let fork a lv f args gs ls = 
    []
  
  
  (** Finalization and other result printing functions: *)

  (** are we still race free *)
  let race_free = ref true

  (** modules used for grouping [varinfo]s by [Offset] *)
  module OffsMap = Map.Make (Offs)
  (** modules used for grouping [varinfo]s by [Offset] *)
  module OffsSet = Set.Make (Offs)

  type access_status = 
    | Race
    | Guarded of Lockset.t
    | ReadOnly
    | ThreadLocal

  (** [postprocess_acc gl] groups and report races in [gl] *)
  let postprocess_acc (gl : Cil.varinfo) =
    (* create mapping from offset to access list; set of offsets  *)
    let create_map (accesses_map: AccValSet.t) =
      let f (((_, _, rw), _, offs) as accs) (map,set) =
        if OffsMap.mem offs map
        then (OffsMap.add offs ([accs] @ (OffsMap.find offs map)) map,
              OffsSet.add offs set)
        else (OffsMap.add offs [accs] map,
              OffsSet.add offs set)
      in
      AccValSet.fold f accesses_map (OffsMap.empty, OffsSet.empty)
    in 
    (* Change lock element offset o to match access offset a *)
    let rec offs_perel o a =
      match a, o with
        | Offs.Offs `Index (i1,a), `Index (i2,o) 
            when ValueDomain.ID.equal i1 i2
            -> `Index (ValueDomain.ID.of_int GU.inthack, offs_perel o (Offs.Offs a))
        | Offs.Offs `Index (_,a), `Index (i,o) -> `Index (i,offs_perel o (Offs.Offs a))
        | Offs.Offs `Field (_,a), `Field (f,o) -> `Field (f,offs_perel o (Offs.Offs a)) 
        | _ -> o
    in
    (* join map elements, that we cannot be sure are logically separate *)
    let regroup_map (map,set) =
      let f offs (group_offs, access_list, new_map) = 
        let process (oa:Offs.t) (op:Offs.t) = 
          let prc_acc (bs, ls, os) = 
            match per_elementize oa op ls with
              | Some (lv,lo) -> 
                  (bs,Dom.singleton (Addr.from_var_offset (lv,offs_perel lo oa), true), os)
              | None -> (bs,Dom.empty (),os)
          in
          List.map prc_acc 
        in
        (* We assume f is called in the right order: we get the greatest offset first (leq'wise) 
           That also means that we get unknown indexes first.*)
        (* At first we take the definite part of an offset --- if that's all 
           then go to f_definite else try to record that as a per-element 
           access protection and proceed to f_perel *)
        let new_offs = Offs.definite offs in
        let f_definite () = 
          (* Offset was definite -- current offset the offsets that follow and are 
            smaller (have extra indexes ond/or fields) are to be considered as one.*)
          let new_gr_offs = Offs.join new_offs group_offs in
          if (Offs.leq new_offs group_offs || (Offs.is_bot group_offs)) 
          then (new_gr_offs, OffsMap.find offs map @ access_list, new_map) 
          else (   new_offs, OffsMap.find offs map, OffsMap.add group_offs access_list new_map)         
        in
        let f_perel () =
          (* Offset was not definite --- almost same as with f_definite, but keep only 
             per-element locks. *)
          let new_gr_offs = Offs.perelem_join offs group_offs in
          let accs = OffsMap.find offs map in
          if (Offs.perel_leq offs group_offs || (Offs.is_bot group_offs)) 
          then (new_gr_offs, process offs new_gr_offs accs @ access_list, new_map) 
          else (       offs, accs, OffsMap.add group_offs access_list new_map)         
        in
        (* Were we precise enough to have definite variable access or must we try to 
           generate per-element invariants. *)
        if (Offs.equal offs new_offs) && (Offs.equal group_offs (Offs.definite group_offs))
        then f_definite ()
        else f_perel ()
      in
      let (last_offs,last_set, map) = OffsSet.fold f set (Offs.bot (), [], OffsMap.empty) in
        if Offs.is_bot last_offs
        then map
        else OffsMap.add last_offs last_set map
    in
    let get_common_locks acc_list = 
      let f locks ((_,_,writing), lock, _) = 
        let lock = 
          if writing then
            (* when writing: ignore reader locks *)
            Lockset.filter snd lock 
          else 
            (* when reading: bump reader locks to exclusive as they protect reads *)
            Lockset.map (fun (x,_) -> (x,true)) lock 
        in
          Lockset.join locks lock 
      in
			List.fold_left f (Lockset.bot ()) acc_list
    in
    let is_race acc_list =
      let locks = get_common_locks acc_list in
      let rw ((_,_,x),_,_) = x in
      let non_main ((_,x,_),_,_) = BS.Flag.is_bad x in      
        if not (List.exists rw acc_list) then
          ReadOnly
        else if not (Lockset.is_empty locks || Lockset.is_top locks) then
          Guarded locks
        else if not (List.exists non_main acc_list) then
          ThreadLocal
        else
          Race
    in
    let report_race offset acc_list =
        let f  ((loc, fl, write), lockset,o) = 
          let lockstr = Lockset.short 80 lockset in
          let action = if write then "write" else "read" in
          let thread = if BS.Flag.is_bad fl then "some thread" else "main thread" in
          let warn = (*gl.vname ^ Offs.short 80 o ^ " " ^*) action ^ " in " ^ thread ^ " with lockset: " ^ lockstr in
            (warn,loc) in 
        let warnings =  List.map f acc_list in
            let var_str = gl.vname ^ Offs.short 80 offset in
        let safe_str reason = "Safely accessed " ^ var_str ^ " (" ^ reason ^ ")" in
          match is_race acc_list with
            | Race -> begin
                race_free := false;
                let warn = "Datarace over " ^ var_str in
                  M.print_group warn warnings
              end
            | Guarded locks ->
                let lock_str = Lockset.short 80 locks in
                  if !GU.allglobs then
                    M.print_group (safe_str "common mutex") warnings
                  else 
                    ignore (printf "Found correlation: %s is guarded by lockset %s\n" var_str lock_str)
            | ReadOnly ->
                if !GU.allglobs then
                  M.print_group (safe_str "only read") warnings
            | ThreadLocal ->
                if !GU.allglobs then
                  M.print_group (safe_str "thread local") warnings
    in 
    let rw ((_,_,x),_,_) = x in
    let acc = (Acc.find acc gl) in
    let acc = if !no_read then AccValSet.filter rw acc else acc in
    let acc_info = create_map acc in
    let acc_map = if !unmerged_fields then fst acc_info else regroup_map acc_info in
      OffsMap.iter report_race acc_map
    
  (** postprocess and print races and other output *)
  let finalize () = 
    AccKeySet.iter postprocess_acc !accKeys;
    if !GU.multi_threaded then begin
      match !race_free, !M.soundness with
        | true, true -> 
            print_endline "CONGRATULATIONS!\nYour program has just been certified Free of Data Races!";
            if not (!failing_locks) then print_endline  "(Assuming locking operations always succeed.)"
        | true, false -> 
            print_endline "Goblint did not find any Data Races in this program!";
            print_endline "However, the code was too complicated for Goblint to understand all of it."
        | false, true -> 
            print_endline "And that's all. Goblint is certain there are no other races.";
            if not (!failing_locks) then print_endline  "(Assuming locking operations always succeed.)"
        | _ -> 
            print_endline "And there may be more races ...";
            print_endline "The code was too complicated for Goblint to understand all of it."
    end else if not !GU.debug then begin
      print_endline "NB! That didn't seem like a multithreaded program.";
      print_endline "Try `goblint --help' to do something other than Data Race Analysis."
    end;
    BS.finalize ()

end


(** Data race analyzer --- this is the old one with integrated base analysis. *)  
module Spec : Analyses.Spec =
struct  

  (** name for the analysis (btw, it's "Mutex Must") *)
  let name = "Mutex Must"

  (** a strange function *)
  let es_to_string f es = f.svar.vname
  
  (** no init. needed -- call [BS.init] *)
  let init = BS.init 

  (** Add current lockset alongside to the base analysis domain. Global data is collected using dirty side-effecting. *)
  module Dom = Lattice.Prod (BS.Dom) (Lockset)
  
  (** We do not add global state, so just lift from [BS]*)
  module Glob = BS.Glob
  
  let get_diff (x,_) = BS.get_diff x
  let reset_diff (x,y) = (BS.reset_diff x, y)
  
  (** queries *)
  let query _ _ (x:Dom.t) (q:Queries.t) : Queries.Result.t = Queries.Result.top ()

  (** Access counting is done using side-effect (accesses added in [add_accesses] and read in [finalize]) : *)
  
  (* 
    Access counting using side-effects: ('|->' is a hash-map)
    
    acc     : var |-> (loc, mt_flag, rw_falg, lockset, offset) set
    accKeys : var set
    
    Remark:
    As you can see, [accKeys] is just premature optimization, so we dont have to iterate over [acc] to get all keys.
   *)
  module Acc = Hashtbl.Make (Basetype.Variables)
  module AccKeySet = Set.Make (Basetype.Variables)
  module AccValSet = Set.Make (Printable.Prod3 (Printable.Prod3 (Basetype.ProgLines) (BS.Flag) (IntDomain.Booleans)) (Lockset) (Offs))
  let acc     : AccValSet.t Acc.t = Acc.create 100
  let accKeys : AccKeySet.t ref   = ref AccKeySet.empty 
  
  (** Function [add_accesses accs st] fills the hash-map [acc] *)
  let add_accesses (accessed: (varinfo * Offs.t * bool) list) (bst,ust:Dom.t) : unit = 
    if not !GU.may_narrow then begin
      let fl = BS.get_fl bst in
      if BS.Flag.is_multi fl then
        let loc = !GU.current_loc in
        let try_add_one (v, o, rv: Cil.varinfo * Offs.t * bool) =
          if (v.vglob) then
            let curr : AccValSet.t = try Acc.find acc v with Not_found -> AccValSet.empty in
            let neww : AccValSet.t = AccValSet.add ((loc,fl,rv),ust,o) curr in
            Acc.replace acc v neww;
            accKeys := AccKeySet.add v !accKeys
        in 
          List.iter try_add_one accessed
    end


  (** First we consider reasonable joining states if locksets are equal, also we don't expect precision if base state is equal*)
  let should_join (x,a) (y,b) = Lockset.equal a b || BS.Dom.equal x y
  
  (** We just lift start state, global and dependecy functions: *)
  
  let startstate () = BS.startstate (), Lockset.empty ()
  let otherstate () = BS.otherstate (), Lockset.empty ()
  
  
  (** Transfer functions: *)
  
  let assign a lval rval gs (bst,ust: Dom.t) : Dom.t = 
    let accessed = BS.access_one_byval a true gs bst (Lval lval) @ BS.access_one_byval a false gs bst rval in
    add_accesses accessed (bst,ust) ;
    (BS.assign a lval rval gs bst, ust)
    
  let branch a exp tv gs (bst,ust: Dom.t) : Dom.t =
    let accessed = BS.access_one_byval a false gs bst exp in
    add_accesses accessed (bst,ust);
    (BS.branch a exp tv gs bst, ust)
    
  let return a exp fundec gs (bst,ust: Dom.t) : Dom.t =
    begin match exp with 
      | Some exp -> 
          let accessed = BS.access_one_byval a false gs bst exp in
          add_accesses accessed (bst,ust)
      | None -> () end;
      (BS.return a exp fundec gs bst, ust)
        
  let body a f gs (bst,ust: Dom.t) : Dom.t = 
    (BS.body a f gs bst, ust)

  let eval_funvar a exp gs (bst,bl) = 
    let read = BS.access_one_byval a false gs bst exp in
    add_accesses read (bst,bl); 
    BS.eval_funvar a exp gs bst
  
  let special_fn a lv f arglist gs (bst,ls: Dom.t) : (Dom.t * Cil.exp * bool) list =
    let eval_exp_addr context exp =
      let v = BS.eval_rv a gs context exp in
        match v with
          | `Address v when not (AD.is_top v) -> AD.fold (fun a b -> a :: b) v []    
          | _                                 -> []
    in
    let true_exp = (Cil.integer 1) in
    let map_bs x = List.map (fun (y,_,_) -> y, x) (BS.special_fn a lv f arglist gs bst) in
    let m_true x = x, true_exp, true in
    let map_bst x = List.map m_true (map_bs x) in
    let lock rw =
        let lock_one (e:LockDomain.Addr.t) =
          let set_ret v sts = 
            match lv with 
              | None -> sts
              | Some lv ->
                let lv_addr = BS.eval_lv a gs bst lv in
                List.map (fun (b,u) -> BS.set gs b lv_addr v, u) sts 
          in 
          List.map m_true (
          set_ret (`Int (ID.of_int 0L)) (map_bs (Lockset.add (e,rw) ls)) @
          if !failing_locks then set_ret (`Int (ID.of_excl_list [0L])) (map_bs ls) else []
                          )
        in
        let unknown () = 
          match lv with 
            | None -> map_bst ls
            | Some lv ->  
                let lv_addr = BS.eval_lv a gs bst lv in
                List.map (fun (b,u) -> m_true(BS.set gs b lv_addr (`Int (ID.top ())), u)) (map_bs ls)  
        in
          match arglist with
            | [x] -> begin match  (eval_exp_addr bst x) with 
                             | [e]  -> lock_one e
                             | _ -> unknown ()
                     end
            | _ -> unknown ()
    in
    let remove_rw x st = Lockset.remove (x,true) (Lockset.remove (x,false) st) in
    let unlock remove_fn =
      match arglist with
        | [x] -> begin match  (eval_exp_addr bst x) with 
                        | [] -> map_bst (Lockset.empty ())
                        | es -> map_bst (List.fold_right remove_fn es ls)
                end
        | _ -> map_bst ls
    in
    match f.vname with
   (* | "sem_wait"*)
      | "_spin_lock" | "_spin_lock_irqsave" | "_spin_trylock" | "_spin_trylock_irqsave" | "_spin_lock_bh"
      | "mutex_lock" | "mutex_lock_interruptible" | "pthread_mutex_trylock" | "_write_lock"
      | "pthread_mutex_lock" | "pthread_rwlock_wrlock" | "pthread_rwlock_trywrlock"
          -> lock true
      | "pthread_rwlock_tryrdlock" | "pthread_rwlock_rdlock" | "_read_lock" 
          -> lock false
      | "__raw_read_unlock" | "__raw_write_unlock" -> 
          let drop_raw_lock x =
            let rec drop_offs o = 
              match o with
                | `Field ({fname="raw_lock"},`NoOffset) -> `NoOffset
                | `Field (f1,o1) -> `Field (f1, drop_offs o1)
                | `Index (i1,o1) -> `Index (i1, drop_offs o1)
                | `NoOffset -> `NoOffset
            in
            match Addr.to_var_offset x with
              | [(v,o)] -> Addr.from_var_offset (v, drop_offs o)
              | _ -> x
          in
          unlock (fun l -> remove_rw (drop_raw_lock l))
   (* | "sem_post"*)
      | "_spin_unlock" | "_spin_unlock_irqrestore" | "_spin_unlock_bh"
      | "mutex_unlock"  
      | "pthread_mutex_unlock" 
          -> unlock remove_rw
      | x -> 
          let arg_acc act = 
            match LF.get_invalidate_action x with
              | Some fnc -> (fnc act arglist) 
              | _ -> []
          in
          let read       = BS.access_byval a false gs bst (arg_acc `Read) in
          let accessable = BS.access_byref a       gs bst (arg_acc `Write) in
          add_accesses (read @ accessable) (bst,ls);
          map_bst ls
          
  let enter_func a lv f args gs (bst,lst) : (Dom.t * Dom.t) list =
    List.map (fun (bf,st) -> (bf,lst),(st,lst)) (BS.enter_func a lv f args gs bst) 

  let leave_func a lv f args gs (bst,bl) (ast,al) = 
    let read = BS.access_byval a false gs bst args in
    add_accesses read (bst,bl); 
    let rslt = BS.leave_func a lv f args gs bst ast in
    (rslt, al)
    
  let fork a lv f args gs (bst,ls) = 
    List.map (fun (f,t) -> (f,(t,ls))) (BS.fork a lv f args gs bst)
  
  
  (** Finalization and other result printing functions: *)

  (** are we still race free *)
  let race_free = ref true

  (** modules used for grouping [varinfo]s by [Offset] *)
  module OffsMap = Map.Make (Offs)
  (** modules used for grouping [varinfo]s by [Offset] *)
  module OffsSet = Set.Make (Offs)

  type access_status = 
    | Race
    | Guarded of Lockset.t
    | ReadOnly
    | ThreadLocal

  (** [postprocess_acc gl] groups and report races in [gl] *)
  let postprocess_acc (gl : Cil.varinfo) =
    (* create mapping from offset to access list; set of offsets  *)
    let create_map (accesses_map: AccValSet.t) =
      let f (((_, _, rw), _, offs) as accs) (map,set) =
        if OffsMap.mem offs map
        then (OffsMap.add offs ([accs] @ (OffsMap.find offs map)) map,
              OffsSet.add offs set)
        else (OffsMap.add offs [accs] map,
              OffsSet.add offs set)
      in
      AccValSet.fold f accesses_map (OffsMap.empty, OffsSet.empty)
    in 
    (* join map elements, that we cannot be sure are logically separate *)
    let regroup_map (map,set) =
      let f offs (group_offs, access_list, new_map) = 
        let new_offs = Offs.definite offs in
        let new_gr_offs = Offs.join new_offs group_offs in
        (* we assume f is called in the right order: we get the greatest offset first (leq'wise) *)
        if (Offs.leq new_offs group_offs || (Offs.is_bot group_offs)) 
        then (new_gr_offs, OffsMap.find offs map @ access_list, new_map) 
        else (   new_offs, OffsMap.find offs map, OffsMap.add group_offs access_list new_map) 
      in
      let (last_offs,last_set, map) = OffsSet.fold f set (Offs.bot (), [], OffsMap.empty) in
        if Offs.is_bot last_offs
        then map
        else OffsMap.add last_offs last_set map
    in
    let get_common_locks acc_list = 
      let f locks ((_,_,writing), lock, _) = 
        let lock = 
          if writing then
            (* when writing: ignore reader locks *)
            Lockset.filter snd lock 
          else 
            (* when reading: bump reader locks to exclusive as they protect reads *)
            Lockset.map (fun (x,_) -> (x,true)) lock 
        in
          Lockset.join locks lock 
      in
                        List.fold_left f (Lockset.bot ()) acc_list
    in
    let is_race acc_list =
      let locks = get_common_locks acc_list in
      let rw ((_,_,x),_,_) = x in
      let non_main ((_,x,_),_,_) = BS.Flag.is_bad x in      
        if not (Lockset.is_empty locks || Lockset.is_top locks) then
          Guarded locks
        else if not (List.exists rw acc_list) then
          ReadOnly
        else if not (List.exists non_main acc_list) then
          ThreadLocal
        else
          Race
    in
    let report_race offset acc_list =
        let f  ((loc, fl, write), lockset,o) = 
          let lockstr = Lockset.short 80 lockset in
          let action = if write then "write" else "read" in
          let thread = if BS.Flag.is_bad fl then "some thread" else "main thread" in
          let warn = (*gl.vname ^ Offs.short 80 o ^ " " ^*) action ^ " in " ^ thread ^ " with lockset: " ^ lockstr in
            (warn,loc) in 
        let warnings =  List.map f acc_list in
            let var_str = gl.vname ^ Offs.short 80 offset in
        let safe_str reason = "Safely accessed " ^ var_str ^ " (" ^ reason ^ ")" in
          match is_race acc_list with
            | Race -> begin
                race_free := false;
                let warn = "Datarace over " ^ var_str in
                  M.print_group warn warnings
              end
            | Guarded locks ->
                let lock_str = Lockset.short 80 locks in
                  if !GU.allglobs then
                    M.print_group (safe_str "common mutex") warnings
                  else 
                    ignore (printf "Found correlation: %s is guarded by lockset %s\n" var_str lock_str)
            | ReadOnly ->
                if !GU.allglobs then
                  M.print_group (safe_str "only read") warnings
            | ThreadLocal ->
                if !GU.allglobs then
                  M.print_group (safe_str "thread local") warnings
    in 
    let rw ((_,_,x),_,_) = x in
    let acc = (Acc.find acc gl) in
    let acc = if !no_read then AccValSet.filter rw acc else acc in
    let acc_info = create_map acc in
    let acc_map = if !unmerged_fields then fst acc_info else regroup_map acc_info in
      OffsMap.iter report_race acc_map
    
  (** postprocess and print races and other output *)
  let finalize () = 
    AccKeySet.iter postprocess_acc !accKeys;
    if !GU.multi_threaded then begin
      match !race_free, !M.soundness with
        | true, true -> 
            print_endline "CONGRATULATIONS!\nYour program has just been certified Free of Data Races!";
            if not (!failing_locks) then print_endline  "(Assuming locking operations always succeed.)"
        | true, false -> 
            print_endline "Goblint did not find any Data Races in this program!";
            print_endline "However, the code was too complicated for Goblint to understand all of it."
        | false, true -> 
            print_endline "And that's all. Goblint is certain there are no other races.";
            if not (!failing_locks) then print_endline  "(Assuming locking operations always succeed.)"
        | _ -> 
            print_endline "And there may be more races ...";
            print_endline "The code was too complicated for Goblint to understand all of it."
    end else if not !GU.debug then begin
      print_endline "NB! That didn't seem like a multithreaded program.";
      print_endline "Try `goblint --help' to do something other than Data Race Analysis."
    end;
    BS.finalize ()

end


module Path = Compose.PathSensitive (Spec)

module Analysis = Multithread.Forward(Path)
module SimpleAnalysis = Multithread.Forward(Spec)

