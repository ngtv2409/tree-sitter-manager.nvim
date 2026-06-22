local config = require("tree-sitter-manager.config")
local util = require("tree-sitter-manager.util")
local backport = require("tree-sitter-manager.backport")

---@class Installer
---@field installing table<Lang, boolean>
---@field status     table<Lang, Status>
---@field remove  fun(lang:Lang|Lang[], callback:fun(out:Status)) Remove languages and run callback.
---@field install fun(lang:Lang|Lang[], callback:fun(out:Status)) Install languages and run callback on every language.
---@field update  fun(lang:Lang|Lang[], callback:fun(out:Status)) Update languages and run callback on every language.
---
---@alias Lang string
local M = { installing = {}, status = {} }

local function copy_queries(lang, source)
    source = source or vim.fs.joinpath(util.PLUGIN_ROOT, "runtime/queries", lang)
    if vim.uv.fs_stat(source) then
        return util.copy_dir(source, util.qpath(lang))
    else
        return { ok = false, error = "copy_queries(" .. lang .. ")\n" .. source .. " not found" }
    end
end

local function treesitter_build(lang, query_dir, build_path, generate, tmpdir, status, callback)
    _status = { ok = status.ok and generate, error = status.error }
    if _status.ok then
        vim.notify("⚙️ Generating " .. lang)
    end
    util.run_async({ "tree-sitter", "generate" }, build_path, _status, function(out)
        if not generate then
            out = status
        end
        if out.ok then
            vim.notify("🔨 Building " .. lang)
        end
        util.run_async({ "tree-sitter", "build", "-o", util.ppath(lang) }, build_path, out, function(out)
            if out.ok then
                out = copy_queries(lang, query_dir and vim.fs.joinpath(build_path, query_dir))
            end
            vim.fs.rm(tmpdir, { recursive = true, force = true })
            callback(out)
        end)
    end)
end

local function install(lang, callback)
    if util.is_only_query(lang) then
        callback(copy_queries(lang))
        return
    end

    local out = util.run({ "git", "version" })
    if not out.ok then
        callback({ ok = false, error = "Git not installed" })
        return
    end
    version = { out.output:match("(%d+)%.(%d+)%.(%d+)") }
    local major = tonumber(version[1])
    local minor = tonumber(version[2])
    local patch = tonumber(version[3])

    local info = util.get_repo_info(lang)
    local tmpdir = vim.fn.tempname()
    local build_path = vim.fs.joinpath(tmpdir, info.location)

    if info.revision and (major < 2 or major == 2 and minor < 49) then
        -- Git pre 2.49.0 doesn't have --revision flag
        out = util.run({ "git", "init", tmpdir })
        if out.ok then
            out = util.run({ "git", "remote", "add", "origin", info.url }, tmpdir)
        end
        util.run_async({ "git", "fetch", "--depth=1", "origin", info.revision }, tmpdir, out, function(out)
            if out.ok then
                out = util.run({ "git", "checkout", "FETCH_HEAD" }, tmpdir)
            end
            treesitter_build(
                lang,
                info.use_repo_queries and info.queries,
                build_path,
                info.generate,
                tmpdir,
                out,
                callback
            )
        end)
    else
        local revision = info.revision and "--revision=" .. info.revision
        local branch = info.branch and "--branch=" .. info.branch
        util.run_async(
            { "git", "--no-advice", "clone", "--depth=1", info.url, tmpdir, revision or branch },
            nil,
            out,
            function(out)
                treesitter_build(
                    lang,
                    info.use_repo_queries and info.queries,
                    build_path,
                    info.generate,
                    tmpdir,
                    out,
                    callback
                )
            end
        )
    end
end

function M.remove(languages, callback, update)
    languages = type(languages) == "string" and { languages } or languages
    callback = callback or function() end

    local uninstalled = {}
    for _, lang in ipairs(languages) do
        if util.is_installed(lang) then
            vim.fs.rm(util.ppath(lang), { recursive = true, force = true })
            vim.fs.rm(util.qpath(lang), { recursive = true, force = true })
            M.status[lang] = nil
            table.insert(uninstalled, lang)
        end
    end

    if not update and #uninstalled > 0 then
        vim.notify("✕ Removed " .. table.concat(languages, " "))
        callback({ ok = true })
    end
end

function M.install(languages, callback, update)
    languages = type(languages) == "string" and { languages } or languages
    callback = callback or function() end

    for _, lang in ipairs(languages) do
        vim.list.unique(vim.list_extend(languages, util.get_requires(lang)))
    end

    local installing = {}
    for _, lang in ipairs(languages) do
        if not config.effective_repos[lang] then
            M.status[lang] = { ok = false, error = "Parser not found in repos" }
            vim.notify("⚠ Parser not found in repos: " .. lang, vim.log.levels.WARN)
        elseif util.is_installed(lang) then
            M.status[lang] = { ok = true }
        elseif not M.installing[lang] then
            install(lang, function(out)
                M.status[lang] = out
                M.installing[lang] = nil
                if not out.ok then
                    vim.notify("⚠ Error installing " .. lang .. "\n" .. out.error, vim.log.levels.WARN)
                else
                    vim.notify("✓ " .. (update and "Updated " or "Installed ") .. lang)
                    -- refresh queries and update highlighting
                    vim.treesitter.query.get:clear()
                    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                        pcall(vim.treesitter.start, buf)
                    end
                end
                callback(out)
            end)
            if not util.is_only_query(lang) then
                M.installing[lang] = true
                table.insert(installing, lang)
            end
        end
    end

    if #installing > 0 then
        if update then
            vim.notify("󰚰 Updating " .. table.concat(installing, " "))
        else
            vim.notify("📦 Installing " .. table.concat(installing, " "))
        end
    end
end

function M.update(languages, callback)
    M.remove(languages, callback, true)
    M.install(languages, callback, true)
end

-- Backward compatibility
backport._install_single = install

return M
