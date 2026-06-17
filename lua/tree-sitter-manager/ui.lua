local config = require("tree-sitter-manager.config")
local util = require("tree-sitter-manager.util")
local installer = require("tree-sitter-manager.installer")

local glyph_icon = { "*", "🌳" }
local glyph_ok = { "OK", "✅" }
local glyph_warn = { "!!", "⚠️" }
local glyph_fail = { "..", "❌" }
local glyph_index = 2

local title = "Tree-sitter Parser Manager"
local footer = " [i] Install  [x] Remove  [u] Update  [r] Refresh  [f] Filter  [q] Close "

local function get_status(lang)
    if not util.is_installed(lang) then
        return "fail"
    end

    for _, dep in ipairs(util.get_requires(lang)) do
        if not util.is_installed(dep) then
            return "warn"
        end
    end

    return "ok"
end

-- Only show these status
-- Maybe add configureable default
local filter_d = {
    ok = true,
    warn = true,
    fail = true,
}
local filter = filter_d
-- Input: comma seperated list
local function ask_status_filter()
    local input = vim.fn.input("Filter (ok,warn,fail) or empty for default. Comma seperated\n: ")

    if not input or input == "" then
        return vim.deepcopy(filter_d)
    end

    local filter = {
        ok = false,
        warn = false,
        fail = false,
    }

    for part in input:gmatch("[^,]+") do
        local v = part:lower():gsub("%s+", "")
        if filter[v] ~= nil then
            filter[v] = true
        end
    end

    return filter
end
local function get_lang_filtered()
    local langs = config.languages
    local filtered = {}

    for i = 1, #langs do
        local v = langs[i]
        if filter[get_status(v)] then
            filtered[#filtered + 1] = v
        end
    end
    return filtered
end

local M = {}

local function get_status_icon(lang)
    if not util.is_installed(lang) then
        return glyph_fail[glyph_index]
    end

    for _, dep in ipairs(util.get_requires(lang)) do
        if not util.is_installed(dep) then
            return glyph_warn[glyph_index]
        end
    end

    return glyph_ok[glyph_index]
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

function M.render(buf)
    local lines = {}
    for _, l in ipairs(get_lang_filtered()) do
        table.insert(lines, string.format("   %-18s  %s%s", l, get_status_icon(l), get_meta_suffix(l)))
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

function M.open()
    local max_w = #footer
    for _, l in ipairs(config.languages) do
        max_w = math.max(max_w, #("   " .. l .. "  XX  abc1234  requires:x,y"))
    end
    local w = math.max(max_w + 4, 40)
    local h = math.min(#config.languages + 6, vim.o.lines - 15)

    glyph_index = config.cfg.nerdfont and 2 or 1

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = w,
        height = h,
        style = "minimal",
        border = config.cfg.border,
        row = math.floor((vim.o.lines - h) / 2),
        col = math.floor((vim.o.columns - w) / 2),
        title = " " .. glyph_icon[glyph_index] .. " " .. title .. " ",
        title_pos = "center",
        footer = footer,
        footer_pos = "center",
    })
    M.render(buf)

    local close_fn = function()
        vim.api.nvim_win_close(win, true)
    end
    vim.keymap.set("n", "q", close_fn, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", close_fn, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "r", function()
        M.render(buf)
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "i", function()
        M._act("install")
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "x", function()
        M._act("remove")
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "u", function()
        M._act("update")
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "f", function()
        filter = ask_status_filter()
        M.render(buf)
    end, { buffer = buf, noremap = true, silent = true })
end

function M._act(action)
    local lang = vim.api.nvim_get_current_line():match("^%s*([%w_]+)")
    if not lang or not config.effective_repos[lang] then
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    if action == "install" then
        installer.install(lang, function(out)
            if out.ok then
                M.render(buf)
            end
        end)
    elseif action == "remove" then
        installer.remove(lang)
        M.render(buf)
    elseif action == "update" then
        installer.remove(lang)
        installer.install(lang, function(out)
            if out.ok then
                M.render(buf)
            end
        end)
    end
end

return M
