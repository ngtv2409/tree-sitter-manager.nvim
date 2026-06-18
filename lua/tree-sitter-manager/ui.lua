local config = require("tree-sitter-manager.config")
local util = require("tree-sitter-manager.util")
local installer = require("tree-sitter-manager.installer")

local buf = vim.api.nvim_create_buf(false, true)
local filter_type = {
    --      ok    warn  miss
    [0] = { true, true, true }, --   all
    [1] = { true, true, false }, --  installed
    [2] = { false, true, false }, -- warning
    [3] = { false, false, true }, -- missing
}
local filter = 0
local langs = {}
local maxlang, maxline = 0, 0

local icon = {
    title = { "*", "🌳" },
    status = {
        { "OK", "✅" }, -- ok
        { "!!", "⚠️" }, -- warning
        { "..", "❌" }, -- missing
    },
}
local icon_index = 2
local title = "Tree-sitter Parser Manager"
local footer = " [i] Install  [x] Remove  [u] Update  [r] Refresh  [f] Filter  [q] Close "

local M = {}

local function get_status(lang)
    if not util.is_installed(lang) then
        return 3 -- missing
    end
    for _, dep in ipairs(util.get_requires(lang)) do
        if not util.is_installed(dep) then
            return 2 -- warning
        end
    end
    return 1 -- ok
end

local function get_meta_suffix(lang)
    local info = util.get_repo_info(lang)
    local parts = {}
    if info and info.revision then
        table.insert(parts, string.sub(info.revision, 1, 7))
    end
    local reqs = util.get_requires(lang)
    if #reqs > 0 then
        table.insert(parts, "requires:" .. table.concat(reqs, ","))
    end
    return #parts > 0 and "  " .. table.concat(parts, " ") or ""
end

local function filter_langs()
    langs = {}
    for _, lang in ipairs(config.languages) do
        maxlang = math.max(maxlang, #lang)
        if filter_type[filter][get_status(lang)] then
            langs[#langs + 1] = lang
        end
    end
end

function M.render()
    local lines = {}
    maxline = 0
    for _, lang in ipairs(langs) do
        local line = string.format("   %-" .. maxlang .. "s  ", lang)
            .. icon.status[get_status(lang)][icon_index]
            .. get_meta_suffix(lang)
        maxline = math.max(maxline, #line)
        table.insert(lines, line)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

function M.refresh()
    filter = 0
    filter_langs()
    M.render()
end

function M.render_update(out)
    if out and not out.ok then
        return
    end
    local old_langs = langs
    filter_langs() -- merge with new languages
    langs = vim.list.unique(util.concat(old_langs, langs))
    M.render()
end

function M.open()
    icon_index = config.cfg.nerdfont and 2 or 1
    M.refresh()

    local w = math.max(#footer + 4, maxline + 4, 40)
    local h = math.min(#config.languages + 6, vim.o.lines - 15)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = w,
        height = h,
        style = "minimal",
        border = config.cfg.border,
        row = math.floor((vim.o.lines - h) / 2),
        col = math.floor((vim.o.columns - w) / 2),
        title = " " .. icon.title[icon_index] .. " " .. title .. " ",
        title_pos = "center",
        footer = footer,
        footer_pos = "center",
    })

    local close_fn = function()
        vim.api.nvim_win_close(win, true)
    end
    vim.keymap.set("n", "q", close_fn, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", close_fn, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "r", M.refresh, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "i", function()
        local lang = vim.api.nvim_get_current_line():match("^%s*([%w_]+)")
        if lang then
            installer.install(lang, M.render_update)
        end
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "x", function()
        local lang = vim.api.nvim_get_current_line():match("^%s*([%w_]+)")
        if lang then
            installer.remove(lang)
            M.render_update()
        end
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "u", function()
        local lang = vim.api.nvim_get_current_line():match("^%s*([%w_]+)")
        if lang then
            installer.remove(lang)
            M.render_update()
            installer.install(lang, M.render_update)
        end
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "f", function()
        repeat -- cycle through filter modes skipping empty and duplicate results
            local old_langs = langs
            filter = (filter + 1) % 4
            filter_langs()
        until #langs > 0 and (filter == 0 or not vim.deep_equal(old_langs, langs))
        M.render()
    end, { buffer = buf, noremap = true, silent = true })
end

return M
