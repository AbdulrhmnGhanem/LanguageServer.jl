"""
    LanguageServerInstance(pipe_in, pipe_out, env="", depot="", err_handler=nothing, symserver_store_path=nothing)

Construct an instance of the language server.

Once the instance is `run`, it will read JSON-RPC from `pipe_out` and
write JSON-RPC from `pipe_in` according to the [language server
specification](https://microsoft.github.io/language-server-protocol/specifications/specification-3-14/).
For normal usage, the language server can be instantiated with
`LanguageServerInstance(stdin, stdout, false, "/path/to/environment")`.

# Arguments
- `pipe_in::IO`: Pipe to read JSON-RPC from.
- `pipe_out::IO`: Pipe to write JSON-RPC to.
- `env::String`: Path to the
  [environment](https://docs.julialang.org/en/v1.2/manual/code-loading/#Environments-1)
  for which the language server is running. An empty string uses julia's
  default environment.
- `depot::String`: Sets the
  [`JULIA_DEPOT_PATH`](https://docs.julialang.org/en/v1.2/manual/environment-variables/#JULIA_DEPOT_PATH-1)
  where the language server looks for packages required in `env`.
- `err_handler::Union{Nothing,Function}`: If not `nothing`, catch all errors and pass them to an error handler
  function with signature `err_handler(err, bt)`. Mostly used for the VS Code crash reporting implementation.
- `symserver_store_path::Union{Nothing,String}`: if `nothing` is passed, the symbol server cash is stored in
  a folder in the package. If an absolute path is passed, the symbol server will store the cache files in that
  path. The path must exist on disc before this is called.
"""
mutable struct LanguageServerInstance
    jr_endpoint::Union{JSONRPC.JSONRPCEndpoint,Nothing}
    workspaceFolders::Set{String}
    _documents::Dict{URI2,Document}

    env_path::String
    depot_path::String
    symbol_server::SymbolServer.SymbolServerInstance
    symbol_results_channel::Channel{Any}
    global_env::StaticLint.ExternalEnv
    roots_env_map::Dict{Document,StaticLint.ExternalEnv}
    symbol_store_ready::Bool
    workspacepackages::Dict{String,Document}
    format_options::DocumentFormat.FormatOptions
    runlinter::Bool
    lint_options::StaticLint.LintOptions
    lint_missingrefs::Symbol
    lint_disableddirs::Vector{String}
    completion_mode::Symbol

    combined_msg_queue::Channel{Any}

    err_handler::Union{Nothing,Function}

    status::Symbol

    number_of_outstanding_symserver_requests::Int
    symserver_use_download::Bool

    current_symserver_progress_token::Union{Nothing,String}

    clientcapability_window_workdoneprogress::Bool
    clientcapability_workspace_didChangeConfiguration::Bool
    # Can probably drop the above 2 and use the below.
    clientCapabilities::Union{ClientCapabilities,Missing}
    clientInfo::Union{InfoParams,Missing}

    shutdown_requested::Bool

    function LanguageServerInstance(pipe_in, pipe_out, env_path="", depot_path="", err_handler=nothing, symserver_store_path=nothing, download=true)
        new(
            JSONRPC.JSONRPCEndpoint(pipe_in, pipe_out, err_handler),
            Set{String}(),
            Dict{URI2,Document}(),
            env_path,
            depot_path,
            SymbolServer.SymbolServerInstance(depot_path, symserver_store_path),
            Channel(Inf),
            StaticLint.ExternalEnv(deepcopy(SymbolServer.stdlibs), SymbolServer.collect_extended_methods(SymbolServer.stdlibs), collect(keys(SymbolServer.stdlibs))),
            Dict(),
            false,
            Dict{String,Document}(),
            DocumentFormat.FormatOptions(),
            true,
            StaticLint.LintOptions(),
            :all,
            LINT_DIABLED_DIRS,
            :qualify, # options: :import or :qualify, anything else turns this off
            Channel{Any}(Inf),
            err_handler,
            :created,
            0,
            download,
            nothing,
            false,
            false,
            missing,
            missing,
            false
        )
    end
end
function Base.display(server::LanguageServerInstance)
    println("Root: ", server.workspaceFolders)
    for d in getdocuments_value(server)
        display(d)
    end
end

function hasdocument(server::LanguageServerInstance, uri::URI2)
    return haskey(server._documents, uri)
end

function getdocument(server::LanguageServerInstance, uri::URI2)
    return server._documents[uri]
end

function getdocuments_key(server::LanguageServerInstance)
    return keys(server._documents)
end

function getdocuments_pair(server::LanguageServerInstance)
    return pairs(server._documents)
end

function getdocuments_value(server::LanguageServerInstance)
    return values(server._documents)
end

function setdocument!(server::LanguageServerInstance, uri::URI2, doc::Document)
    server._documents[uri] = doc
    # Add possible workspace packages
    path = uri2filepath(uri._uri)
    for wk_folder in server.workspaceFolders
        if startswith(path, wk_folder) && normpath(wk_folder) == normpath(server.env_path)
            sub_path = splitpath(path)
            first(sub_path) == "/" && popfirst!(sub_path)
            length(sub_path) < 3 && continue
            fname = splitext(last(sub_path))[1]
            if sub_path[end-1] == "src" && sub_path[end-2] == fname
                @info "Setting $path as source of 'live' package"
                server.workspacepackages[fname] = doc
            end
        end
    end
    return doc
end

function deletedocument!(server::LanguageServerInstance, uri::URI2)
    # clear reference to doc from workspacepackages
    for (n,d) in server.workspacepackages
        if d._uri == uri._uri
            delete!(server.workspacepackages, n)
            break
        end
    end
    doc = getdocument(server, uri)
    StaticLint.clear_meta(getcst(doc))
    delete!(server._documents, uri)

    for d in getdocuments_value(server)
        if getroot(d) === doc
            setroot(d, d)
            semantic_pass(getroot(d))
        end
    end
end

function create_symserver_progress_ui(server)
    if server.clientcapability_window_workdoneprogress
        token = string(uuid4())
        server.current_symserver_progress_token = token
        JSONRPC.send(server.jr_endpoint, window_workDoneProgress_create_request_type, WorkDoneProgressCreateParams(token))

        JSONRPC.send(
            server.jr_endpoint,
            progress_notification_type,
            ProgressParams(token, WorkDoneProgressBegin("Julia Language Server", missing, "Indexing packages...", missing))
        )
    end
end

function destroy_symserver_progress_ui(server)
    if server.clientcapability_window_workdoneprogress && server.current_symserver_progress_token !== nothing
        progress_token = server.current_symserver_progress_token
        server.current_symserver_progress_token = nothing
        JSONRPC.send(
            server.jr_endpoint,
            progress_notification_type,
            ProgressParams(progress_token, WorkDoneProgressEnd(missing))
        )
    end
end

function trigger_symbolstore_reload(server::LanguageServerInstance)
    server.symbol_store_ready = false
    if server.number_of_outstanding_symserver_requests == 0 && server.status == :running
        create_symserver_progress_ui(server)
    end
    server.number_of_outstanding_symserver_requests += 1

    if server.symserver_use_download
        @debug "Will download symbol server caches for this instance."
    end

    @async try
        # TODO Add try catch handler that links into crash reporting
        ssi_ret, payload = SymbolServer.getstore(
            server.symbol_server,
            server.env_path,
            function (i)
                if server.clientcapability_window_workdoneprogress && server.current_symserver_progress_token !== nothing
                    JSONRPC.send(
                        server.jr_endpoint,
                        progress_notification_type,
                        ProgressParams(server.current_symserver_progress_token, WorkDoneProgressReport(missing, "Indexing $i...", missing))
                    )
                else
                    @info "Indexing $i..."
                end
            end,
            server.err_handler,
            download = server.symserver_use_download
        )

        server.number_of_outstanding_symserver_requests -= 1

        if server.number_of_outstanding_symserver_requests == 0
            destroy_symserver_progress_ui(server)
        end

        if ssi_ret == :success
            push!(server.symbol_results_channel, payload)
        elseif ssi_ret == :failure
            error_payload = Dict(
                "command" => "symserv_crash",
                "name" => "LSSymbolServerFailure",
                "message" => payload === nothing ? "" : String(take!(payload)),
                "stacktrace" => "")
            JSONRPC.send(
                server.jr_endpoint,
                telemetry_event_notification_type,
                error_payload
            )
        elseif ssi_ret == :package_load_crash
            error_payload = Dict(
                "command" => "symserv_pkgload_crash",
                "name" => payload.package_name,
                "message" => payload.stderr === nothing ? "" : String(take!(payload.stderr)))
            JSONRPC.send(
                server.jr_endpoint,
                telemetry_event_notification_type,
                error_payload
            )
        end
        server.symbol_store_ready = true
    catch err
        bt = catch_backtrace()
        if server.err_handler !== nothing
            server.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
end

function request_wrapper(func, server::LanguageServerInstance)
    return function (conn, params)
        if server.shutdown_requested
            # it's fine to always return a value here, even for notifications, because
            # JSONRPC discards it anyways in that case
            return JSONRPC.JSONRPCError(
                -32600,
                "LS shutdown was requested.",
                nothing
            )
        end
        func(params, server, conn)
    end
end

"""
    run(server::LanguageServerInstance)

Run the language `server`.
"""
function Base.run(server::LanguageServerInstance)
    server.status = :started

    run(server.jr_endpoint)

    trigger_symbolstore_reload(server)

    @async try
        @debug "LS: Starting client listener task."
        while true
            msg = JSONRPC.get_next_message(server.jr_endpoint)
            put!(server.combined_msg_queue, (type = :clientmsg, msg = msg))
        end
    catch err
        bt = catch_backtrace()
        if server.err_handler !== nothing
            server.err_handler(err, bt)
        else
            io = IOBuffer()
            Base.display_error(io, err, bt)
            print(stderr, String(take!(io)))
        end
    finally
        if isopen(server.combined_msg_queue)
            put!(server.combined_msg_queue, (type = :close,))
            close(server.combined_msg_queue)
        end
        @debug "LS: Client listener task done."
    end

    @async try
        @debug "LS: Starting symbol server listener task."
        while true
            msg = take!(server.symbol_results_channel)
            put!(server.combined_msg_queue, (type = :symservmsg, msg = msg))
        end
    catch err
        bt = catch_backtrace()
        if server.err_handler !== nothing
            server.err_handler(err, bt)
        else
            io = IOBuffer()
            Base.display_error(io, err, bt)
            print(stderr, String(take!(io)))
        end
    finally
        if isopen(server.combined_msg_queue)
            put!(server.combined_msg_queue, (type = :close,))
            close(server.combined_msg_queue)
        end
        @debug "LS: Symbol server listener task done."
    end

    msg_dispatcher = JSONRPC.MsgDispatcher()

    msg_dispatcher[textDocument_codeAction_request_type] = request_wrapper(textDocument_codeAction_request, server)
    msg_dispatcher[workspace_executeCommand_request_type] = request_wrapper(workspace_executeCommand_request, server)
    msg_dispatcher[textDocument_completion_request_type] = request_wrapper(textDocument_completion_request, server)
    msg_dispatcher[textDocument_signatureHelp_request_type] = request_wrapper(textDocument_signatureHelp_request, server)
    msg_dispatcher[textDocument_definition_request_type] = request_wrapper(textDocument_definition_request, server)
    msg_dispatcher[textDocument_formatting_request_type] = request_wrapper(textDocument_formatting_request, server)
    msg_dispatcher[textDocument_references_request_type] = request_wrapper(textDocument_references_request, server)
    msg_dispatcher[textDocument_rename_request_type] = request_wrapper(textDocument_rename_request, server)
    msg_dispatcher[textDocument_prepareRename_request_type] = request_wrapper(textDocument_prepareRename_request, server)
    msg_dispatcher[textDocument_documentSymbol_request_type] = request_wrapper(textDocument_documentSymbol_request, server)
    msg_dispatcher[textDocument_documentHighlight_request_type] = request_wrapper(textDocument_documentHighlight_request, server)
    msg_dispatcher[julia_getModuleAt_request_type] = request_wrapper(julia_getModuleAt_request, server)
    msg_dispatcher[julia_getDocAt_request_type] = request_wrapper(julia_getDocAt_request, server)
    msg_dispatcher[textDocument_hover_request_type] = request_wrapper(textDocument_hover_request, server)
    msg_dispatcher[initialize_request_type] = request_wrapper(initialize_request, server)
    msg_dispatcher[initialized_notification_type] = request_wrapper(initialized_notification, server)
    msg_dispatcher[shutdown_request_type] = request_wrapper(shutdown_request, server)
    msg_dispatcher[exit_notification_type] = request_wrapper(exit_notification, server)
    msg_dispatcher[cancel_notification_type] = request_wrapper(cancel_notification, server)
    msg_dispatcher[setTrace_notification_type] = request_wrapper(setTrace_notification, server)
    msg_dispatcher[setTraceNotification_notification_type] = request_wrapper(setTraceNotification_notification, server)
    msg_dispatcher[julia_getCurrentBlockRange_request_type] = request_wrapper(julia_getCurrentBlockRange_request, server)
    msg_dispatcher[julia_activateenvironment_notification_type] = request_wrapper(julia_activateenvironment_notification, server)
    msg_dispatcher[textDocument_didOpen_notification_type] = request_wrapper(textDocument_didOpen_notification, server)
    msg_dispatcher[textDocument_didClose_notification_type] = request_wrapper(textDocument_didClose_notification, server)
    msg_dispatcher[textDocument_didSave_notification_type] = request_wrapper(textDocument_didSave_notification, server)
    msg_dispatcher[textDocument_willSave_notification_type] = request_wrapper(textDocument_willSave_notification, server)
    msg_dispatcher[textDocument_willSaveWaitUntil_request_type] = request_wrapper(textDocument_willSaveWaitUntil_request, server)
    msg_dispatcher[textDocument_didChange_notification_type] = request_wrapper(textDocument_didChange_notification, server)
    msg_dispatcher[workspace_didChangeWatchedFiles_notification_type] = request_wrapper(workspace_didChangeWatchedFiles_notification, server)
    msg_dispatcher[workspace_didChangeConfiguration_notification_type] = request_wrapper(workspace_didChangeConfiguration_notification, server)
    msg_dispatcher[workspace_didChangeWorkspaceFolders_notification_type] = request_wrapper(workspace_didChangeWorkspaceFolders_notification, server)
    msg_dispatcher[workspace_symbol_request_type] = request_wrapper(workspace_symbol_request, server)
    msg_dispatcher[julia_refreshLanguageServer_notification_type] = request_wrapper(julia_refreshLanguageServer_notification, server)
    msg_dispatcher[julia_getDocFromWord_request_type] = request_wrapper(julia_getDocFromWord_request, server)
    msg_dispatcher[textDocument_selectionRange_request_type] = request_wrapper(textDocument_selectionRange_request, server)

    while true
        message = take!(server.combined_msg_queue)

        if message.type == :close
            @info "Shutting down server instance."
            return
        elseif message.type == :clientmsg
            msg = message.msg
            JSONRPC.dispatch_msg(server.jr_endpoint, msg_dispatcher, msg)
        elseif message.type == :symservmsg
            @info "Received new data from Julia Symbol Server."

            server.global_env.symbols = message.msg
            server.global_env.extended_methods = SymbolServer.collect_extended_methods(server.global_env.symbols)
            server.global_env.project_deps = collect(keys(server.global_env.symbols))

            # redo roots_env_map
            for (root, _) in server.roots_env_map
                @debug "resetting get_env_for_root"
                newenv = get_env_for_root(root, server)
                if newenv === nothing
                    delete!(server.roots_env_map, root)
                else
                    server.roots_env_map[root] = newenv
                end
            end

            @debug "starting re-lint of everything"
            relintserver(server)
            @debug "re-lint done"
        end
    end
end

function relintserver(server)
    roots = Set{Document}()
    documents = getdocuments_value(server)
    for doc in documents
        StaticLint.clear_meta(getcst(doc))
        set_doc(getcst(doc), doc)
    end
    for doc in documents
        # only do a pass on documents once
        root = getroot(doc)
        if !(root in roots)
            push!(roots, root)
            semantic_pass(root)
        end
    end
    for doc in documents
        lint!(doc, server)
    end
end
