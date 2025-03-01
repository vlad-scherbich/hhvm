(*
 * Copyright (c) 2018, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

(* Lazy Initialization:

   During Lazy initialization, hh_server tries to do as little work as possible.
   The init_from_saved_state behavior is this:

     Load from saved state -> Parse dirty files -> Naming -> Dirty Typecheck

   The full_init behavior is this: (similar to eager init, but with lazy decl)

     Full Parsing -> Naming -> Full Typecheck (with lazy decl)
*)

(* module Hack_bucket = Bucket *)
open Hh_prelude

(* module Bucket = Hack_bucket *)
open GlobalOptions
open Result.Export
open Reordered_argument_collections
open SearchServiceRunner
open ServerEnv
open ServerInitTypes
module SLC = ServerLocalConfig

type deptable = CustomDeptable of string

let deptable_with_filename (fn : string) : deptable = CustomDeptable fn

let lock_and_load_deptable
    ~(base_file_name : string)
    ~(deptable : deptable)
    ~(ignore_hh_version : bool) : unit =
  match deptable with
  | CustomDeptable fn ->
    let () =
      if
        not
          (Saved_state_loader.ignore_saved_state_version_mismatch
             ~ignore_hh_version)
      then
        let build_revision =
          SaveStateService.saved_state_build_revision_read ~base_file_name
        in
        if not (String.equal build_revision Build_id.build_revision) then
          raise
          @@ Failure
               (Printf.sprintf
                  ("Saved-state build mismatch, this saved-state was built "
                  ^^ " for version '%s', but we expected '%s'")
                  build_revision
                  Build_id.build_revision)
    in
    (* The new dependency graph is threaded through function calls
     * instead of stored in a global *)
    Hh_logger.log "Custom dependency graph will be loaded lazily from %s" fn

let run_saved_state_future
    (genv : genv)
    (ctx : Provider_context.t)
    (dependency_table_saved_state_future :
      ( ( Saved_state_loader.Naming_and_dep_table_info.main_artifacts,
          Saved_state_loader.Naming_and_dep_table_info.additional_info )
        Saved_state_loader.load_result,
        ServerInitTypes.load_state_error )
      result
      Future.t) : (loaded_info, load_state_error) result =
  let t = Unix.gettimeofday () in
  match Future.get dependency_table_saved_state_future ~timeout:60 with
  | Error error ->
    Hh_logger.log
      "Unhandled Future.error from state loader: %s"
      (Future.error_to_string error);
    let e = Exception.wrap_unraised (Future.error_to_exn error) in
    Error (Load_state_unhandled_exception e)
  | Ok (Error error) -> Error error
  | Ok (Ok deptable_result) ->
    let (_ : float) =
      Hh_logger.log_duration
        "Finished downloading naming table and dependency graph."
        t
    in
    let {
      Saved_state_loader.main_artifacts;
      additional_info;
      changed_files;
      manifold_path;
      corresponding_rev;
      mergebase_rev;
      is_cached = _;
    } =
      deptable_result
    in
    let {
      Saved_state_loader.Naming_and_dep_table_info.naming_table_path =
        deptable_naming_table_blob_path;
      dep_table_path;
      naming_sqlite_table_path;
      errors_path;
    } =
      main_artifacts
    in
    let {
      Saved_state_loader.Naming_and_dep_table_info.mergebase_global_rev;
      dirty_files_promise;
      saved_state_distance;
      saved_state_age;
    } =
      additional_info
    in
    let ignore_hh_version =
      ServerArgs.ignore_hh_version genv.ServerEnv.options
    in
    let deptable = deptable_with_filename (Path.to_string dep_table_path) in
    lock_and_load_deptable
      ~base_file_name:(Path.to_string deptable_naming_table_blob_path)
      ~deptable
      ~ignore_hh_version;
    let naming_table_fallback_path =
      if Sys.file_exists (Path.to_string naming_sqlite_table_path) then (
        Hh_logger.log "Using sqlite naming table from hack/64 saved state";
        Some (Path.to_string naming_sqlite_table_path)
      ) else
        ServerCheckUtils.get_naming_table_fallback_path genv
    in
    let (old_naming_table, old_errors) =
      SaveStateService.load_saved_state_exn
        ctx
        ~naming_table_fallback_path
        ~errors_path:(Path.to_string errors_path)
    in
    let t = Unix.time () in
    (match
       dirty_files_promise
       |> Future.get
            ~timeout:
              genv.local_config.SLC.load_state_natively_dirty_files_timeout
     with
    | Error error -> Error (Load_state_dirty_files_failure error)
    | Ok
        {
          Saved_state_loader.Naming_and_dep_table_info.master_changes =
            dirty_master_files;
          local_changes = dirty_local_files;
        } ->
      let () = HackEventLogger.state_loader_dirty_files t in
      let dirty_naming_files = Relative_path.Set.of_list changed_files in
      let dirty_master_files = dirty_master_files in
      let dirty_local_files = dirty_local_files in
      let naming_table_manifold_path = Some manifold_path in
      let saved_state_delta =
        match (saved_state_distance, saved_state_age) with
        | (_, None)
        | (None, _) ->
          None
        | (Some distance, Some age) -> Some { distance; age }
      in
      Ok
        {
          naming_table_fn = Path.to_string naming_sqlite_table_path;
          deptable_fn = Path.to_string dep_table_path;
          naming_table_fallback_fn = naming_table_fallback_path;
          corresponding_rev = Hg.Hg_rev corresponding_rev;
          mergebase_rev = mergebase_global_rev;
          mergebase = Some mergebase_rev;
          dirty_naming_files;
          dirty_master_files;
          dirty_local_files;
          old_naming_table;
          old_errors;
          saved_state_delta;
          naming_table_manifold_path;
        })

(** [report update p ~other] is called because we just got a report that progress-meter [p]
should be updated with latest information [update]. The behavior of this function
is to (1) update progress-meter [p], and (2) report overall hh_server status,
making a judgment-call about what message to synthesize out of the progress
of both [p] and [other]. *)
let report
    (update : (Exec_command.t * string list) option)
    (progress : (string * float) option ref)
    ~(other : (string * float) option ref) =
  begin
    match update with
    | None -> progress := None
    | Some (cmd, _args) ->
      progress :=
        Some
          (Exec_command.to_string cmd |> Filename.basename, Unix.gettimeofday ())
  end;
  (* To keep reporting human-understandable, we have to account for the fact that there
     are actually two concurrent progress-meters going on, and we want to keep things
     simple, so we only report the single longest-running of the two progress-meters' updates. *)
  let msg =
    match (!progress, !other) with
    | (None, None) -> "loading saved state" (* if neither is going on *)
    | (None, Some (msg, _time))
    | (Some (msg, _time), None) ->
      Printf.sprintf "waiting on %s..." msg
    | (Some (msg1, time1), Some (_msg2, time2)) when Float.(time1 < time2) ->
      Printf.sprintf "waiting on %s..." msg1
    | (Some _, Some (msg2, _)) -> Printf.sprintf "waiting on %s..." msg2
  in
  ServerProgress.write "%s" msg;
  ()

let download_and_load_state_exn
    ~(genv : ServerEnv.genv) ~(ctx : Provider_context.t) ~(root : Path.t) :
    (loaded_info, load_state_error) result =
  let ignore_hh_version = ServerArgs.ignore_hh_version genv.options in
  let (progress_naming_table_load, progress_dep_table_load) =
    (ref None, ref None)
  in
  let ssopt = genv.local_config.ServerLocalConfig.saved_state in
  let dependency_table_saved_state_future :
      ( ( Saved_state_loader.Naming_and_dep_table_info.main_artifacts,
          Saved_state_loader.Naming_and_dep_table_info.additional_info )
        Saved_state_loader.load_result,
        ServerInitTypes.load_state_error )
      result
      Future.t =
    Hh_logger.log "Downloading dependency graph from DevX infra";
    let loader_future =
      State_loader_futures.load
        ~ssopt
        ~progress_callback:(fun update ->
          report
            update
            progress_dep_table_load
            ~other:progress_naming_table_load)
        ~watchman_opts:
          Saved_state_loader.Watchman_options.{ root; sockname = None }
        ~ignore_hh_version
        ~saved_state_type:Saved_state_loader.Naming_and_dep_table_distc
      |> Future.with_timeout
           ~timeout:genv.local_config.SLC.load_state_natively_download_timeout
    in
    let loader_future =
      Future.continue_with loader_future @@ function
      | Error e -> Error (Load_state_saved_state_loader_failure e)
      | Ok v -> Ok v
    in
    loader_future
  in
  run_saved_state_future genv ctx dependency_table_saved_state_future

let calculate_state_distance_and_age_from_hg
    (root : Path.t) (corresponding_base_revision : string) :
    Hg.hg_rev option * Hg.global_rev option * ServerEnv.saved_state_delta option
    =
  let root = Path.to_string root in
  let future =
    Future.continue_with_future (Hg.current_mergebase_hg_rev root)
    @@ fun mergebase_rev ->
    Future.continue_with_future
      (Hg.get_closest_global_ancestor mergebase_rev root)
    @@ fun mergebase_global_rev ->
    Future.continue_with_future
      (Hg.get_closest_global_ancestor corresponding_base_revision root)
    @@ fun corresponding_base_global_rev ->
    Future.continue_with_future
      (Hg.get_hg_revision_time (Hg.Hg_rev corresponding_base_revision) root)
    @@ fun corresponding_time ->
    Future.continue_with_future
      (Hg.get_hg_revision_time (Hg.Hg_rev mergebase_rev) root)
    @@ fun mergebase_time ->
    let state_distance =
      abs (mergebase_global_rev - corresponding_base_global_rev)
    in
    let state_age = abs (mergebase_time - corresponding_time) in
    let saved_state_delta = { age = state_age; distance = state_distance } in
    Future.of_value (mergebase_rev, mergebase_global_rev, saved_state_delta)
  in
  match Future.get future with
  | Ok (a, b, c) -> (Some a, Some b, Some c)
  | Error e ->
    Hh_logger.log
      "[serverLazyInit]: calculate_state_distance_and_age_from_hg failed: %s"
      (Future.error_to_string e);
    (None, None, None)

let use_precomputed_state_exn
    ~(root : Path.t)
    (genv : ServerEnv.genv)
    (ctx : Provider_context.t)
    (info : ServerArgs.saved_state_target_info)
    (cgroup_steps : CgroupProfiler.step_group) : loaded_info =
  let {
    ServerArgs.naming_table_path;
    corresponding_base_revision;
    deptable_fn;
    changes;
    naming_changes;
    prechecked_changes;
  } =
    info
  in
  let ignore_hh_version = ServerArgs.ignore_hh_version genv.ServerEnv.options in
  let deptable = deptable_with_filename deptable_fn in
  CgroupProfiler.step_start_end cgroup_steps "load deptable"
  @@ fun _cgroup_step ->
  lock_and_load_deptable
    ~base_file_name:naming_table_path
    ~deptable
    ~ignore_hh_version;
  let changes = Relative_path.set_of_list changes in
  let naming_changes = Relative_path.set_of_list naming_changes in
  let prechecked_changes = Relative_path.set_of_list prechecked_changes in
  let naming_sqlite_table_path =
    ServerArgs.naming_sqlite_path_for_target_info info
  in
  let naming_table_fallback_path =
    if Sys.file_exists naming_sqlite_table_path then (
      Hh_logger.log "Using sqlite naming table from saved state";
      Some naming_sqlite_table_path
    ) else
      ServerCheckUtils.get_naming_table_fallback_path genv
  in
  let errors_path = ServerArgs.errors_path_for_target_info info in
  let (old_naming_table, old_errors) =
    CgroupProfiler.step_start_end cgroup_steps "load saved state"
    @@ fun _cgroup_step ->
    SaveStateService.load_saved_state_exn
      ctx
      ~naming_table_fallback_path
      ~errors_path
  in
  let log_saved_state_age_and_distance =
    ctx
    |> Provider_context.get_tcopt
    |> TypecheckerOptions.log_saved_state_age_and_distance
  in
  let (mergebase, mergebase_rev, saved_state_delta) =
    if log_saved_state_age_and_distance then
      calculate_state_distance_and_age_from_hg root corresponding_base_revision
    else
      (None, None, None)
  in
  {
    naming_table_fn = naming_table_path;
    deptable_fn;
    naming_table_fallback_fn = naming_table_fallback_path;
    corresponding_rev = Hg.Hg_rev corresponding_base_revision;
    mergebase_rev;
    mergebase;
    dirty_naming_files = naming_changes;
    dirty_master_files = prechecked_changes;
    dirty_local_files = changes;
    old_naming_table;
    old_errors;
    saved_state_delta;
    naming_table_manifold_path = None;
  }

(** This function ensures the naming-table is ready for us to do [update_reverse_naming_table_from_env_and_get_duplicate_name_errors]
on the [env.naming_table] forward-naming-table files.
- In the case of saved-state-init, [env.naming_table] has dirty files so we'll
  remove them from the global naming table
- In the case of full init, I don't believe this is ever called...!
*)
let remove_items_from_reverse_naming_table_or_build_new_reverse_naming_table
    (ctx : Provider_context.t)
    (old_naming_table : Naming_table.t)
    (parsing_files : Relative_path.Set.t)
    (naming_table_fallback_fn : string option)
    (t : float)
    ~(cgroup_steps : CgroupProfiler.step_group) : float =
  CgroupProfiler.step_start_end cgroup_steps "naming from saved state"
  @@ fun _cgroup_step ->
  begin
    match naming_table_fallback_fn with
    | Some _ ->
      (* Set the SQLite fallback path for the reverse naming table, then block out all entries in
         any dirty files to make sure we properly handle file deletes. *)
      Relative_path.Set.iter parsing_files ~f:(fun k ->
          let open FileInfo in
          match Naming_table.get_file_info old_naming_table k with
          | None ->
            (* If we can't find the file in [old_naming_table] we don't consider that an error, since
             * it could be a new file that was added. *)
            ()
          | Some
              {
                hash = _;
                file_mode = _;
                funs;
                classes;
                typedefs;
                consts;
                modules;
                comments = _;
              } ->
            let backend = Provider_context.get_backend ctx in
            let snd (_, x, _) = x in
            Naming_provider.remove_type_batch
              backend
              (classes |> List.map ~f:snd);
            Naming_provider.remove_type_batch
              backend
              (typedefs |> List.map ~f:snd);
            Naming_provider.remove_fun_batch backend (funs |> List.map ~f:snd);
            Naming_provider.remove_const_batch
              backend
              (consts |> List.map ~f:snd);
            Naming_provider.remove_module_batch
              backend
              (modules |> List.map ~f:snd))
    | None ->
      HackEventLogger.invariant_violation_bug
        "unexpected saved-state build-new-reverse-naming-table";
      (* Name all the files from the old naming-table (except the new ones we parsed since
         they'll be named by our caller, next). We assume the old naming-table came from a clean
         state, which is why we skip checking for "already bound" conditions. *)
      let old_hack_names =
        Naming_table.filter old_naming_table ~f:(fun k _v ->
            not (Relative_path.Set.mem parsing_files k))
      in
      Naming_table.fold old_hack_names ~init:() ~f:(fun k info () ->
          Naming_global.ndecl_file_skip_if_already_bound ctx k info)
  end;
  HackEventLogger.naming_from_saved_state_end t;
  Hh_logger.log_duration "NAMING_FROM_SAVED_STATE_END" t

(* Prechecked files are gated with a flag and not supported in AI/check/saving
 * of saved state modes. *)
let use_prechecked_files (genv : ServerEnv.genv) : bool =
  ServerPrecheckedFiles.should_use genv.options genv.local_config
  && Option.is_none (ServerArgs.ai_mode genv.options)
  && (not (ServerArgs.check_mode genv.options))
  && Option.is_none (ServerArgs.save_filename genv.options)

let get_old_and_new_defs_in_files
    (old_naming_table : Naming_table.t)
    (new_defs_per_file : FileInfo.names Relative_path.Map.t)
    (files : Relative_path.Set.t) : FileInfo.names Relative_path.Map.t =
  Relative_path.Set.fold
    files
    ~f:
      begin
        fun path acc ->
          let new_defs_in_file =
            Relative_path.Map.find_opt new_defs_per_file path
          in
          let old_defs_in_file =
            Naming_table.get_file_info old_naming_table path
            |> Option.map ~f:FileInfo.simplify
          in
          let all_defs =
            Option.merge
              old_defs_in_file
              new_defs_in_file
              ~f:FileInfo.merge_names
          in
          match all_defs with
          | Some all_defs -> Relative_path.Map.add acc ~key:path ~data:all_defs
          | None -> acc
      end
    ~init:Relative_path.Map.empty

let names_to_deps (names : FileInfo.names) : Typing_deps.DepSet.t =
  let open Typing_deps in
  let { FileInfo.n_funs; n_classes; n_types; n_consts; n_modules } = names in
  let add_deps_of_sset dep_ctor sset depset =
    SSet.fold sset ~init:depset ~f:(fun n acc ->
        DepSet.add acc (Dep.make (dep_ctor n)))
  in
  let deps = add_deps_of_sset (fun n -> Dep.Fun n) n_funs (DepSet.make ()) in
  let deps = add_deps_of_sset (fun n -> Dep.Type n) n_classes deps in
  let deps = add_deps_of_sset (fun n -> Dep.Type n) n_types deps in
  let deps = add_deps_of_sset (fun n -> Dep.GConst n) n_consts deps in
  let deps = add_deps_of_sset (fun n -> Dep.GConstName n) n_consts deps in
  let deps = add_deps_of_sset (fun n -> Dep.Module n) n_modules deps in
  deps

let log_fanout_information to_recheck_deps files_to_recheck =
  (* we use lazy here to avoid expensive string generation when logging
       * is not enabled *)
  Hh_logger.log_lazy ~category:"fanout_information"
  @@ lazy
       Hh_json.(
         json_to_string
         @@ JSON_Object
              [
                ("tag", string_ "saved_state_init_fanout");
                ( "hashes",
                  array_
                    string_
                    Typing_deps.(
                      List.map ~f:Dep.to_hex_string
                      @@ DepSet.elements to_recheck_deps) );
                ( "files",
                  array_
                    string_
                    Relative_path.(
                      List.map ~f:suffix @@ Set.elements files_to_recheck) );
              ])

(** Compare declarations loaded from the saved state to declarations based on
  the current versions of dirty files. This lets us check a smaller set of
  files than the set we'd check if old declarations were not available.
  To be used only when load_decls_from_saved_state is enabled. *)
let get_files_to_recheck
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (old_naming_table : Naming_table.t)
    (new_defs_per_file : FileInfo.names Relative_path.Map.t)
    (defs_per_dirty_file : FileInfo.names Relative_path.Map.t)
    (files_to_redeclare : Relative_path.Set.t) : Relative_path.Set.t =
  let bucket_size = genv.local_config.SLC.type_decl_bucket_size in
  let defs_per_file_to_redeclare =
    Relative_path.Set.fold
      files_to_redeclare
      ~init:Relative_path.Map.empty
      ~f:(fun path acc ->
        match Relative_path.Map.find_opt defs_per_dirty_file path with
        | Some info -> Relative_path.Map.add acc ~key:path ~data:info
        | None -> acc)
  in
  let get_old_and_new_classes path : SSet.t =
    let old_names =
      Naming_table.get_file_info old_naming_table path
      |> Option.map ~f:FileInfo.simplify
    in
    let new_names = Relative_path.Map.find_opt new_defs_per_file path in
    let classes_from_names x = x.FileInfo.n_classes in
    let old_classes = Option.map old_names ~f:classes_from_names in
    let new_classes = Option.map new_names ~f:classes_from_names in
    Option.merge old_classes new_classes ~f:SSet.union
    |> Option.value ~default:SSet.empty
  in
  let dirty_names =
    Relative_path.Map.fold
      defs_per_dirty_file
      ~init:FileInfo.empty_names
      ~f:(fun _ -> FileInfo.merge_names)
  in
  let ctx = Provider_utils.ctx_from_server_env env in
  Decl_redecl_service.oldify_type_decl
    ctx
    ~bucket_size
    genv.workers
    get_old_and_new_classes
    ~defs:dirty_names;
  let { Decl_redecl_service.fanout = { Decl_redecl_service.to_recheck; _ }; _ }
      =
    Decl_redecl_service.redo_type_decl
      ~bucket_size
      ctx
      ~during_init:true
      genv.workers
      get_old_and_new_classes
      ~previously_oldified_defs:dirty_names
      ~defs:defs_per_file_to_redeclare
  in
  Decl_redecl_service.remove_old_defs ctx ~bucket_size genv.workers dirty_names;
  let files_to_recheck = Naming_provider.get_files ctx to_recheck in
  log_fanout_information to_recheck files_to_recheck;
  files_to_recheck

(* We start off with a list of files that have changed since the state was
 * saved (dirty_files), the naming table from the saved state (old_naming_table)
 * and a map of the current class / function declarations per file (new_defs_per_file).
 * We grab the declarations from both, to account for both the declarations
 * that were deleted and those that are newly created.
 * Then we use the deptable to figure out the files that
 * referred to them. Finally we recheck the lot.
 *
 * Args:
 *
 * genv, env : environments
 * old_naming_table: naming table at the time of the saved state
 * new_defs_per_file: newly parsed file ast
 * dirty_master_files and dirty_local_files: we need to typecheck these and,
 *    since their decl have changed, also all of their dependencies
 * similar_files: we only need to typecheck these,
 *    not their dependencies since their decl are unchanged
 * *)
let calculate_fanout_and_defer_or_do_type_check
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (old_naming_table : Naming_table.t)
    (new_defs_per_file : FileInfo.names Relative_path.Map.t)
    ~(dirty_master_files_unchanged_hash : Relative_path.Set.t)
    ~(dirty_master_files_changed_hash : Relative_path.Set.t)
    ~(dirty_local_files_unchanged_hash : Relative_path.Set.t)
    ~(dirty_local_files_changed_hash : Relative_path.Set.t)
    (t : float)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  let start_t = Unix.gettimeofday () in
  let dirty_files_unchanged_hash =
    Relative_path.Set.union
      dirty_master_files_unchanged_hash
      dirty_local_files_unchanged_hash
  in
  let dirty_files_changed_hash =
    Relative_path.Set.union
      dirty_master_files_changed_hash
      dirty_local_files_changed_hash
  in
  let old_and_new_defs_per_dirty_files_changed_hash =
    get_old_and_new_defs_in_files
      old_naming_table
      new_defs_per_file
      dirty_files_changed_hash
  in
  let old_and_new_defs_in_files files : FileInfo.names =
    Relative_path.Map.fold
      old_and_new_defs_per_dirty_files_changed_hash
      ~f:
        begin
          fun k v acc ->
            if Relative_path.Set.mem files k then
              FileInfo.merge_names v acc
            else
              acc
        end
      ~init:FileInfo.empty_names
  in
  let ctx = Provider_utils.ctx_from_server_env env in
  let master_deps =
    old_and_new_defs_in_files dirty_master_files_changed_hash |> names_to_deps
  in
  let local_deps =
    old_and_new_defs_in_files dirty_local_files_changed_hash |> names_to_deps
  in
  let get_files_to_recheck files_to_redeclare =
    get_files_to_recheck
      genv
      env
      old_naming_table
      new_defs_per_file
      (ServerCheckUtils.extend_defs_per_file
         genv
         old_and_new_defs_per_dirty_files_changed_hash
         env.naming_table
         dirty_files_unchanged_hash)
      files_to_redeclare
  in
  let (env, to_recheck) =
    if use_prechecked_files genv then
      (* Start with dirty files and fan-out of local changes only *)
      let to_recheck =
        if
          genv.local_config.SLC.load_decls_from_saved_state
          || genv.local_config.SLC.fetch_remote_old_decls
        then
          get_files_to_recheck dirty_local_files_changed_hash
        else
          let deps = Typing_deps.add_all_deps env.deps_mode local_deps in
          let files = Naming_provider.get_files ctx deps in
          log_fanout_information deps files;
          files
      in
      let env =
        ServerPrecheckedFiles.init
          env
          ~dirty_local_deps:local_deps
          ~dirty_master_deps:master_deps
      in
      (env, to_recheck)
    else
      (* Start with full fan-out immediately *)
      let to_recheck =
        if
          genv.local_config.SLC.load_decls_from_saved_state
          || genv.local_config.SLC.fetch_remote_old_decls
        then
          get_files_to_recheck dirty_files_changed_hash
        else
          let deps = Typing_deps.DepSet.union master_deps local_deps in
          let deps = Typing_deps.add_all_deps env.deps_mode deps in
          let files = Naming_provider.get_files ctx deps in
          log_fanout_information deps files;
          files
      in
      (env, to_recheck)
  in
  (* We still need to typecheck files whose declarations did not change *)
  let to_recheck =
    Relative_path.Set.union to_recheck dirty_files_unchanged_hash
  in
  let defs_per_files_to_recheck =
    ServerCheckUtils.extend_defs_per_file
      genv
      old_and_new_defs_per_dirty_files_changed_hash
      env.naming_table
      to_recheck
  in
  let files_to_check = Relative_path.Map.keys defs_per_files_to_recheck in

  (* HACK: dump the fanout that we calculated and exit. This is for
     `hh_fanout`'s regression testing vs. `hh_server`. This can be deleted once
     we no longer worry about `hh_fanout` regressing vs. `hh_server`. Deletion
     is tracked at T65464119. *)
  if ServerArgs.dump_fanout genv.options then (
    Hh_json.json_to_multiline_output
      stdout
      (Hh_json.JSON_Object
         [
           ( "recheck_files",
             Hh_json.JSON_Array
               (files_to_check
               |> List.map ~f:Relative_path.to_absolute
               |> List.map ~f:Hh_json.string_) );
         ]);
    exit 0
  ) else
    let env = { env with changed_files = dirty_files_changed_hash } in
    let files_to_check =
      if
        not
          genv.ServerEnv.local_config
            .ServerLocalConfig.enable_type_check_filter_files
      then
        files_to_check
      else
        Relative_path.Set.elements
        @@ ServerCheckUtils.user_filter_type_check_files
             ~to_recheck:(Relative_path.Set.of_list files_to_check)
             ~reparsed:
               (Relative_path.Set.union
                  dirty_files_unchanged_hash
                  dirty_files_changed_hash)
             ~is_ide_file:(fun _ -> false)
    in
    let (state_distance, state_age) =
      match env.init_env.saved_state_delta with
      | None -> (None, None)
      | Some { distance; age } -> (Some distance, Some age)
    in
    let init_telemetry =
      ServerEnv.Init_telemetry.make
        ServerEnv.Init_telemetry.Init_lazy_dirty
        (Telemetry.create ()
        |> Telemetry.float_ ~key:"start_time" ~value:start_t
        |> Telemetry.int_
             ~key:"dirty_master_files_unchanged_hash"
             ~value:
               (Relative_path.Set.cardinal dirty_master_files_unchanged_hash)
        |> Telemetry.int_
             ~key:"dirty_master_files_changed_hash"
             ~value:(Relative_path.Set.cardinal dirty_master_files_changed_hash)
        |> Telemetry.int_
             ~key:"dirty_local_files_unchanged_hash"
             ~value:
               (Relative_path.Set.cardinal dirty_local_files_unchanged_hash)
        |> Telemetry.int_
             ~key:"dirty_local_files_changed_hash"
             ~value:(Relative_path.Set.cardinal dirty_local_files_changed_hash)
        |> Telemetry.int_
             ~key:"dirty_files_unchanged_hash"
             ~value:(Relative_path.Set.cardinal dirty_files_unchanged_hash)
        |> Telemetry.int_
             ~key:"dirty_files_changed_hash"
             ~value:(Relative_path.Set.cardinal dirty_files_changed_hash)
        |> Telemetry.int_
             ~key:"to_recheck"
             ~value:(Relative_path.Set.cardinal to_recheck)
        |> Telemetry.int_opt ~key:"state_distance" ~value:state_distance
        |> Telemetry.int_opt ~key:"state_age" ~value:state_age)
    in
    let result =
      ServerInitCommon.defer_or_do_type_check
        genv
        env
        files_to_check
        init_telemetry
        t
        ~telemetry_label:"type_check_dirty"
        ~cgroup_steps
    in
    HackEventLogger.type_check_dirty
      ~start_t
      ~dirty_count:(Relative_path.Set.cardinal dirty_files_changed_hash)
      ~recheck_count:(Relative_path.Set.cardinal to_recheck);
    Hh_logger.log
      "ServerInit type_check_dirty count: %d. recheck count: %d"
      (Relative_path.Set.cardinal dirty_files_changed_hash)
      (Relative_path.Set.cardinal to_recheck);
    result

let get_updates_exn ~(genv : ServerEnv.genv) ~(root : Path.t) :
    Relative_path.Set.t * Watchman.clock option =
  let start_t = Unix.gettimeofday () in
  Hh_logger.log "Getting files changed while parsing...";
  ServerNotifier.wait_until_ready genv.notifier;
  let (changes, clock) = ServerNotifier.get_changes_async genv.notifier in
  let files_changed_while_parsing =
    match changes with
    | ServerNotifier.StateEnter _
    | ServerNotifier.StateLeave _
    | ServerNotifier.Unavailable ->
      Relative_path.Set.empty
    | ServerNotifier.SyncChanges updates
    | ServerNotifier.AsyncChanges updates ->
      let root = Path.to_string root in
      let filter p =
        String.is_prefix p ~prefix:root && FindUtils.file_filter p
      in
      SSet.filter updates ~f:filter
      |> Relative_path.relativize_set Relative_path.Root
  in
  ignore
    (Hh_logger.log_duration
       "Finished getting files changed while parsing"
       start_t
      : float);
  Hh_logger.log "Watchclock: %s" (ServerEnv.show_clock clock);
  HackEventLogger.changed_while_parsing_end start_t;
  (files_changed_while_parsing, clock)

let initialize_naming_table
    (progress_message : string)
    ?(fnl : Relative_path.t list option = None)
    ?(do_naming : bool = false)
    ~(cache_decls : bool)
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  ServerProgress.write "%s" progress_message;
  let (get_next, count, t) =
    match fnl with
    | Some fnl ->
      ( MultiWorker.next genv.workers fnl,
        Some (List.length fnl),
        Unix.gettimeofday () )
    | None ->
      let (get_next, t) =
        ServerInitCommon.directory_walk ~telemetry_label:"lazy.nt.indexing" genv
      in
      (get_next, None, t)
  in
  (* full init - too many files to trace all of them *)
  let trace = false in
  let (env, t) =
    ServerInitCommon.parse_files_and_update_forward_naming_table
      genv
      env
      ~get_next
      ?count
      t
      ~trace
      ~cache_decls
      ~telemetry_label:"lazy.nt.parsing"
      ~cgroup_steps
      ~worker_call:MultiWorker.wrapper
  in
  if do_naming then
    ServerInitCommon
    .update_reverse_naming_table_from_env_and_get_duplicate_name_errors
      env
      t
      ~telemetry_label:"lazy.nt.do_naming.naming"
      ~cgroup_steps
  else
    (env, t)

let write_symbol_info
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (cgroup_steps : CgroupProfiler.step_group)
    (t : float) : ServerEnv.env * float =
  let (env, t) =
    ServerInitCommon
    .update_reverse_naming_table_from_env_and_get_duplicate_name_errors
      env
      t
      ~telemetry_label:"write_symbol_info.naming"
      ~cgroup_steps
  in
  let namespace_map = ParserOptions.auto_namespace_map env.tcopt in
  let paths = env.swriteopt.symbol_write_index_paths in
  let paths_file = env.swriteopt.symbol_write_index_paths_file in
  let referenced_file = env.swriteopt.symbol_write_referenced_out in
  let include_hhi = env.swriteopt.symbol_write_include_hhi in
  let ignore_paths = env.swriteopt.symbol_write_ignore_paths in
  let incremental = env.swriteopt.symbol_write_sym_hash_in in
  let gen_sym_hash = env.swriteopt.symbol_write_sym_hash_out in
  let files =
    if List.length paths > 0 || Option.is_some paths_file then
      Symbol_indexable.from_options ~paths ~paths_file ~include_hhi
    else
      Symbol_indexable.from_naming_table
        env.naming_table
        ~include_hhi
        ~ignore_paths
  in
  match env.swriteopt.symbol_write_index_paths_file_output with
  | Some output ->
    List.map
      ~f:(fun Symbol_indexable.{ path; _ } ->
        Relative_path.storage_to_string path)
      files
    |> Out_channel.write_lines output;
    (env, t)
  | None ->
    let out_dir =
      match ServerArgs.write_symbol_info genv.options with
      | None -> failwith "No write directory specified for --write-symbol-info"
      | Some s -> s
    in
    (* Ensure we are writing to fresh files *)
    let is_invalid =
      try
        if not (Sys.is_directory out_dir) then
          true
        else
          Array.length (Sys.readdir out_dir) > 0
      with
      | _ ->
        Sys_utils.mkdir_p out_dir;
        false
    in
    if is_invalid then failwith "JSON write directory is invalid or non-empty";

    Hh_logger.log "Indexing: %d files" (List.length files);
    Hh_logger.log "Writing JSON to: %s" out_dir;
    (match incremental with
    | Some t -> Hh_logger.log "Reading hashtable from: %s" t
    | None -> ());
    let incremental =
      Option.map ~f:(fun path -> Symbol_sym_hash.read ~path) incremental
    in

    let ctx = Provider_utils.ctx_from_server_env env in
    let root_path = env.swriteopt.symbol_write_root_path in
    let hhi_path = env.swriteopt.symbol_write_hhi_path in
    let ownership = env.swriteopt.symbol_write_ownership in
    Hh_logger.log "Ownership mode: %b" ownership;
    Hh_logger.log "Gen_sym_hash: %b" gen_sym_hash;
    Symbol_entrypoint.go
      genv.workers
      ctx
      ~referenced_file
      ~namespace_map
      ~gen_sym_hash
      ~ownership
      ~out_dir
      ~root_path
      ~hhi_path
      ~incremental
      ~files;

    (env, t)

let write_symbol_info_full_init
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  let (env, t) =
    initialize_naming_table
      ~cache_decls:true
      "write symbol info initialization"
      genv
      env
      cgroup_steps
  in
  write_symbol_info genv env cgroup_steps t

(* If we fail to load a saved state, fall back to typechecking everything *)
let full_init
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  let init_telemetry =
    ServerEnv.Init_telemetry.make
      ServerEnv.Init_telemetry.Init_lazy_full
      (Telemetry.create ()
      |> Telemetry.float_ ~key:"start_time" ~value:(Unix.gettimeofday ()))
  in
  let is_check_mode = ServerArgs.check_mode genv.options in
  let existing_name_count =
    Naming_table.fold env.naming_table ~init:0 ~f:(fun _ _ i -> i + 1)
  in
  if existing_name_count > 0 then begin
    let desc = "full_init_naming_not_empty" in
    Hh_logger.log
      "INVARIANT_VIOLATION_BUG [%s] count=%d"
      desc
      existing_name_count;
    HackEventLogger.invariant_violation_bug desc ~data_int:existing_name_count
  end;
  Hh_logger.log "full init";

  let (env, t) =
    initialize_naming_table
      ~do_naming:true
      ~cache_decls:true
      "full initialization"
      genv
      env
      cgroup_steps
  in
  ServerInitCommon.validate_no_errors env.errorl;
  if not is_check_mode then
    SearchServiceRunner.update_fileinfo_map
      env.naming_table
      ~source:SearchUtils.Init;
  let defs_per_file = Naming_table.to_defs_per_file env.naming_table in
  let fnl = Relative_path.Map.keys defs_per_file in
  ServerInitCommon.defer_or_do_type_check
    genv
    env
    fnl
    init_telemetry
    t
    ~telemetry_label:"lazy.full.type_check"
    ~cgroup_steps

let parse_only_init
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  initialize_naming_table
    ~cache_decls:false
    "parse-only initialization"
    genv
    env
    cgroup_steps

let post_saved_state_initialization
    ~(do_indexing : bool)
    ~(genv : ServerEnv.genv)
    ~(env : ServerEnv.env)
    ~(state_result : loaded_info * Relative_path.Set.t * Watchman.clock option)
    (cgroup_steps : CgroupProfiler.step_group) : ServerEnv.env * float =
  let ((loaded_info : ServerInitTypes.loaded_info), changed_while_parsing, clock)
      =
    state_result
  in
  let trace = genv.local_config.SLC.trace_parsing in
  let {
    naming_table_fallback_fn;
    dirty_naming_files;
    dirty_local_files;
    dirty_master_files;
    old_naming_table;
    mergebase_rev;
    mergebase;
    old_errors;
    deptable_fn;
    naming_table_fn = _;
    corresponding_rev = _;
    saved_state_delta;
    naming_table_manifold_path;
  } =
    loaded_info
  in
  if genv.local_config.SLC.hg_aware then
    if ServerArgs.is_using_precomputed_saved_state genv.options then begin
      HackEventLogger.tried_to_be_hg_aware_with_precomputed_saved_state_warning
        ();
      Hh_logger.log
        "Warning: disabling restart on rebase (server was started with precomputed saved-state)"
    end else
      Option.iter mergebase_rev ~f:ServerRevisionTracker.initialize;
  let env =
    {
      env with
      init_env =
        {
          env.init_env with
          mergebase;
          naming_table_manifold_path;
          saved_state_delta;
        };
      deps_mode =
        (match ServerArgs.save_64bit genv.options with
        | Some new_edges_dir ->
          let human_readable_dep_map_dir =
            ServerArgs.save_human_readable_64bit_dep_map genv.options
          in
          Typing_deps_mode.SaveToDiskMode
            {
              graph = Some deptable_fn;
              new_edges_dir;
              human_readable_dep_map_dir;
            }
        | None -> Typing_deps_mode.InMemoryMode (Some deptable_fn));
    }
  in

  Hh_logger.log
    "Number of files with errors: %d"
    (Relative_path.Set.cardinal old_errors);

  (* Load and parse PACKAGES.toml if it exists at the root. *)
  let (errors, package_info) = PackageConfig.load_and_parse () in
  let env =
    ServerEnv.{ env with package_info; errorl = Errors.merge env.errorl errors }
  in

  (***********************************************************
    INVARIANTS.
    These might help make sense of the rest of the function. *)
  (* Invariant: old_naming_table is Backed, and has empty delta *)
  begin
    match Naming_table.get_backed_delta_TEST_ONLY old_naming_table with
    | None ->
      HackEventLogger.invariant_violation_bug
        "saved-state naming table not backed"
    | Some { Naming_sqlite.file_deltas; _ }
      when not (Relative_path.Map.is_empty file_deltas) ->
      HackEventLogger.invariant_violation_bug
        "saved-state naming table has deltas"
    | Some _ -> ()
  end;
  (* Invariant: env.naming_table is Unbacked and empty *)
  begin
    match Naming_table.get_backed_delta_TEST_ONLY env.naming_table with
    | None -> ()
    | Some _ ->
      HackEventLogger.invariant_violation_bug
        "ServerLazyInit env.naming_table is backed"
  end;
  let count =
    Naming_table.fold env.naming_table ~init:0 ~f:(fun _ _ acc -> acc + 1)
  in
  if count > 0 then
    HackEventLogger.invariant_violation_bug
      "ServerLazyInit env.naming_table is non-empty"
      ~data_int:count;
  (* Invariant: env.disk_needs_parsing and env.needs_recheck are empty *)
  if not (Relative_path.Set.is_empty env.disk_needs_parsing) then
    HackEventLogger.invariant_violation_bug
      "SeverLazyInit env.disk_needs_parsing is non-empty";
  if not (Relative_path.Set.is_empty env.needs_recheck) then
    HackEventLogger.invariant_violation_bug
      "SeverLazyInit env.needs_recheck is non-empty";

  (***********************************************************
    NAMING TABLE.
    Plan: we'll adjust the forward and reverse naming table to reflect
    changes to files which changed since the saved-state. We'll also
    reflect changes in files which had [phase=Errors.(Naming|Parsing)]
    as well. Notionally that's because our current mechanism for handling
    duplicate-name-errors requires all affected files to go through
    the "update reverse naming table" procedure. (but it's redundant
    because, elsewhere, we don't allow saved-state-generation in case
    of naming errors...)

    The actual implementation is confusing because it stores fragments
    of naming-table in places you wouldn't expect:

    1. [old_naming_table], which we got from the saved-state, is a [NamingTable.t]
       that's "backed" i.e. it reflects just the sqlite file plus a delta, initially empty.
    2. [env.naming_table] starts out as [Naming_table.empty] as it was created in
       [ServerMain.setup_server]. We will add to it the forward-naming-table FileInfo.t
       for all files discussed above, [parsing_files]
    3. The reverse naming-table is made up of global mutable shmem delta with
       eventual fallback to sqlite. We will write into that delta the reverse-names
       that arise from the [parsing_files]. The same step also gathers any
       duplicate-name errors.
    4. Finally we'll merge the [env.naming_table] (which is only [parsed_files] at the moment)
       into [old_naming_table] (which represents the sqlite file), and store the result
       back in [env.naming_table]. At this point the naming-table, forward and reverse,
       is complete. *)
  let t = Unix.gettimeofday () in
  let naming_files =
    List.fold
      ~init:Relative_path.Set.empty
      ~f:Relative_path.Set.union
      [
        dirty_naming_files;
        dirty_master_files;
        dirty_local_files;
        changed_while_parsing;
      ]
    |> Relative_path.Set.filter ~f:FindUtils.path_filter
  in
  ( CgroupProfiler.step_start_end cgroup_steps "remove fixmes"
  @@ fun _cgroup_step -> Fixme_provider.remove_batch naming_files );
  (* Parse dirty files only *)
  let (env, t) =
    ServerInitCommon.parse_files_and_update_forward_naming_table
      genv
      env
      ~get_next:
        (MultiWorker.next
           genv.workers
           (Relative_path.Set.elements naming_files))
      ~count:(Relative_path.Set.cardinal naming_files)
      t
      ~trace
      ~cache_decls:false (* Don't overwrite old decls loaded from saved state *)
      ~telemetry_label:"post_ss1.parsing"
      ~cgroup_steps
      ~worker_call:MultiWorker.wrapper
  in
  let defs_per_file = Naming_table.to_defs_per_file env.naming_table in
  SearchServiceRunner.update_fileinfo_map
    env.naming_table
    ~source:SearchUtils.TypeChecker;
  let ctx = Provider_utils.ctx_from_server_env env in
  let t =
    remove_items_from_reverse_naming_table_or_build_new_reverse_naming_table
      ctx
      old_naming_table
      naming_files
      naming_table_fallback_fn
      t
      ~cgroup_steps
  in
  if do_indexing then
    write_symbol_info genv env cgroup_steps t
  else
    (* Do global naming on all dirty files *)
    let (env, t) =
      ServerInitCommon
      .update_reverse_naming_table_from_env_and_get_duplicate_name_errors
        env
        t
        ~telemetry_label:"post_ss1.naming"
        ~cgroup_steps
    in
    ServerInitCommon.validate_no_errors env.errorl;

    let env =
      {
        env with
        clock;
        naming_table = Naming_table.combine old_naming_table env.naming_table;
        disk_needs_parsing = Relative_path.Set.empty;
        needs_recheck = Relative_path.Set.union env.needs_recheck old_errors;
      }
    in

    (***********************************************************
      FANOUT.
      What files should be checked?

      We've already said that files-with-errors from the dirty saved state must be
      rechecked. And we've already produced "duplicate name" errors if needed from
      all the changed files. The question remaining is, what fanout should be checked?

      Here, for each changed file, we compare its hash to the one saved
      in the saved state. If the hashes are the same, then the declarations
      on the file have not changed and we only need to retypecheck that file,
      not all of its dependencies.
      We call these files "similar" to their previous versions.

      A similar check is also made later, inside [calculate_fanout_and_defer_or_do_type_check]
      when it calls [get_files_to_recheck] which calls [Decl_redecl_service.redo_type_decl].
      That obtains old decls from an online service and uses that for decl-diffing.

      Anyway, the effect of this phase is to calculate fanout, techniques to determine
      decl-diffing, using the prechecked algorithm too. Then, the fanout files are
      combined into [env.needs_recheck], as a way of deferring the check until
      the first iteration of ServerTypeCheck.
    *)
    let partition_similar dirty_files =
      Relative_path.Set.partition
        (fun f ->
          let info1 = Naming_table.get_file_info old_naming_table f in
          let info2 = Naming_table.get_file_info env.naming_table f in
          match (info1, info2) with
          | (Some x, Some y) ->
            (match (x.FileInfo.hash, y.FileInfo.hash) with
            | (Some x, Some y) -> Int64.equal x y
            | _ -> false)
          | _ -> false)
        dirty_files
    in
    let (dirty_master_files_unchanged_hash, dirty_master_files_changed_hash) =
      partition_similar dirty_master_files
    in
    let (dirty_local_files_unchanged_hash, dirty_local_files_changed_hash) =
      partition_similar dirty_local_files
    in

    let (env, t) =
      calculate_fanout_and_defer_or_do_type_check
        genv
        env
        old_naming_table
        defs_per_file
        ~dirty_master_files_unchanged_hash
        ~dirty_master_files_changed_hash
        ~dirty_local_files_unchanged_hash
        ~dirty_local_files_changed_hash
        t
        cgroup_steps
    in
    (env, t)

let saved_state_init
    ~(do_indexing : bool)
    ~(load_state_approach : load_state_approach)
    (genv : ServerEnv.genv)
    (env : ServerEnv.env)
    (root : Path.t)
    (cgroup_steps : CgroupProfiler.step_group) :
    ( (ServerEnv.env * float) * (loaded_info * Relative_path.Set.t),
      load_state_error )
    result =
  let t = Unix.gettimeofday () in
  let attempt_fix = genv.local_config.SLC.attempt_fix_credentials in
  let () =
    match Security.check_credentials ~attempt_fix with
    | Ok success ->
      HackEventLogger.credentials_check_end
        (Printf.sprintf "saved_state_init: %s" (Security.show_success success))
        t
    | Error error ->
      let kind = Security.to_error_kind_string error in
      let message = Security.to_error_message_string error in
      Hh_logger.log "Error kind: %s\nError message: %s" kind message;
      HackEventLogger.credentials_check_failure
        (Printf.sprintf "saved_state_init: [%s]" kind)
        t
  in

  ServerProgress.write "loading saved state";

  let ctx = Provider_utils.ctx_from_server_env env in
  let do_ () : (loaded_info, load_state_error) result =
    let state_result =
      CgroupProfiler.step_start_end cgroup_steps "load saved state"
      @@ fun _cgroup_step ->
      match load_state_approach with
      | Precomputed info ->
        Ok (use_precomputed_state_exn ~root genv ctx info cgroup_steps)
      | Load_state_natively -> download_and_load_state_exn ~genv ~ctx ~root
    in
    state_result
  in
  let t = Unix.gettimeofday () in
  let state_result =
    try
      match do_ () with
      | Error error -> Error error
      | Ok loaded_info ->
        let (changed_while_parsing, clock) = get_updates_exn ~genv ~root in
        Ok (loaded_info, changed_while_parsing, clock)
    with
    | exn ->
      let e = Exception.wrap exn in
      Error (Load_state_unhandled_exception e)
  in
  HackEventLogger.saved_state_download_and_load_done
    ~load_state_approach:(show_load_state_approach load_state_approach)
    ~success:(Result.is_ok state_result)
    ~state_result:
      (match state_result with
      | Error _ -> None
      | Ok (i, _, _) -> Some (show_loaded_info i))
    t;
  match state_result with
  | Error err -> Error err
  | Ok (loaded_info, changed_while_parsing, clock) ->
    ServerProgress.write "loading saved state succeeded";
    Hh_logger.log "Watchclock: %s" (ServerEnv.show_clock clock);
    let (env, t) =
      post_saved_state_initialization
        ~do_indexing
        ~state_result:(loaded_info, changed_while_parsing, clock)
        ~env
        ~genv
        cgroup_steps
    in
    Ok ((env, t), (loaded_info, changed_while_parsing))
