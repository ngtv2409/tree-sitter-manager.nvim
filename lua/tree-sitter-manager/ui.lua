local config = require("tree-sitter-manager.config")
local util = require("tree-sitter-manager.util")
local installer = require("tree-sitter-manager.installer")
local backport = require("tree-sitter-manager.backport")

local title_asci = " Tree-sitter Parser Manager "
local title_nerd = " 🌳 Tree-sitter Parser Manager "
local status_asci = { "OK", "!!", ".." }
local status_nerd = { "✅", "⚠️", "❌" }
local footer = " [i] Install  [x] Remove  [u] Update  [r] Refresh  [f] Filter  [q] Close "
local filter_type = {
    --      ok    warn  miss
    [0] = { true, true, true }, --   all
    [1] = { true, true, false }, --  installed
    [2] = { false, true, false }, -- warning
    [3] = { false, false, true }, -- missing
}

local frames = { "⣾ ", "⣽ ", "⣻ ", "⢿ ", "⡿ ", "⣟ ", "⣯ ", "⣷ " }

local ns = vim.api.nvim_create_namespace("tree-sitter-manager.spinner")
local spinning = {} -- table<lang, { timer, mark_id, row, frame }>

local buf, win, langs, filter_idx, title, status_icon, formatter
local langwidth, icon_col

local M = {}

function M.setup()
    title = config.cfg.nerdfont and title_nerd or title_asci
    status_icon = config.cfg.nerdfont and status_nerd or status_asci
    langwidth = vim.iter(config.languages):map(string.len):fold(0, math.max)
    icon_col = langwidth + 5 -- 3 leading spaces + langwidth chars + 2 separator spaces
    formatter = "   %-" .. langwidth .. "s  %s%s"
end

local function get_status(lang)
    if not util.is_installed(lang) then
        return 3 -- missing
    elseif vim.iter(util.get_requires(lang)):all(util.is_installed) then
        return 1 -- ok
    else
        return 2 -- warning
    end
end

local function get_status_icon_iter(langs)
    local function get_icon(status)
        return status_icon[status]
    end
    return vim.iter(langs):map(get_status):map(get_icon)
end

local function get_meta_suffix(lang)
    local info = util.get_repo_info(lang)
    local parts = {}
    if info and info.revision then
        local rev = #info.revision == 40 and string.sub(info.revision, 1, 7) or info.revision
        table.insert(parts, string.format("%-7s", rev))
    end
    local reqs = util.get_requires(lang)
    if #reqs > 0 then
        vim.list_extend(parts, { "requires:", unpack(reqs) })
    end
    return #parts > 0 and "  " .. table.concat(parts, " ") or ""
end

local function filter(lang)
    return filter_type[filter_idx][get_status(lang)]
end

local function get_langs_filtered()
    return vim.iter(config.languages):filter(filter):totable()
end

local function cycle_filter()
    local new_langs
    repeat -- skip empty results and duplicates
        filter_idx = (filter_idx + 1) % 4
        new_langs = get_langs_filtered()
    until filter_idx == 0 or #new_langs > 0 and not vim.deep_equal(langs, new_langs)
    langs = new_langs
    M.render()
end

local function lang_row(lang)
    for i, l in ipairs(langs) do
        if l == lang then
            return i - 1
        end
    end
end

local function start_spinner(lang, row)
    if spinning[lang] then
        return
    end

    local f = 1
    local mid = vim.api.nvim_buf_set_extmark(buf, ns, row, icon_col, {
        virt_text = { { frames[f], "Special" } },
        virt_text_pos = "overlay",
    })

    local timer = vim.uv.new_timer()
    timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            local s = spinning[lang]
            if not s then
                if not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                return
            end

            if not vim.api.nvim_buf_is_valid(buf) then
                if not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                spinning[lang] = nil
                return
            end

            f = (f % #frames) + 1
            s.frame = f
            if s.mark_id then
                vim.api.nvim_buf_set_extmark(buf, ns, s.row, icon_col, {
                    id = mid,
                    virt_text = { { frames[f], "Special" } },
                    virt_text_pos = "overlay",
                })
            end
        end)
    )
    spinning[lang] = { timer = timer, mark_id = mid, row = row, frame = f }
end

local function stop_spinner(lang)
    local s = spinning[lang]
    if not s then
        return
    end

    if not s.timer:is_closing() then
        s.timer:stop()
        s.timer:close()
    end

    if vim.api.nvim_buf_is_valid(buf) and s.mark_id then
        vim.api.nvim_buf_del_extmark(buf, ns, s.mark_id)
    end
    spinning[lang] = nil
end

-- After any buffer rewrite, re-anchor active spinner extmarks to their current
-- rows. Handles row drift when M.render(out) sorts new langs into the list, or
-- when M.open resets langs to config.languages, or when a filter change hides
-- or reveals a spinning lang.
local function sync_spinners()
    for lang, s in pairs(spinning) do
        local row = lang_row(lang)
        if row and s.mark_id then
            -- Lang still visible: reposition the existing extmark.
            s.row = row
            vim.api.nvim_buf_set_extmark(buf, ns, row, icon_col, {
                id = s.mark_id,
                virt_text = { { frames[s.frame], "Special" } },
                virt_text_pos = "overlay",
            })
        elseif row and not s.mark_id then
            -- Lang was hidden but is visible again: create a fresh extmark.
            s.row = row
            s.mark_id = vim.api.nvim_buf_set_extmark(buf, ns, row, icon_col, {
                virt_text = { { frames[s.frame], "Special" } },
                virt_text_pos = "overlay",
            })
        elseif not row and s.mark_id then
            -- Lang just became hidden by the filter: delete the orphaned extmark.
            vim.api.nvim_buf_del_extmark(buf, ns, s.mark_id)
            s.mark_id = nil
        end
        -- not row and not s.mark_id: still hidden, nothing to do.
    end
end

local act = setmetatable({}, {
    __index = function(act, action)
        local function _action()
            local lang = vim.api.nvim_get_current_line():match("^%s*([%w_]+)")
            if lang then
                local function on_done(out)
                    for l in pairs(spinning) do
                        if not installer.installing[l] then
                            stop_spinner(l)
                        end
                    end
                    M.render(out)
                end
                installer[action](lang, on_done)

                for l in pairs(installer.installing) do
                    local row = lang_row(l)
                    if row then
                        start_spinner(l, row)
                    end
                end
            end
        end
        rawset(act, action, _action)
        return _action
    end,
})

function M.render(out)
    if not buf then
        return 0
    elseif out then -- update langs on callback
        table.sort(vim.list.unique(vim.list_extend(langs, get_langs_filtered())))
    end

    local status = get_status_icon_iter(langs)
    local meta = vim.iter(langs):map(get_meta_suffix)
    local lines = vim.iter(langs)
        :map(function(lang)
            return formatter:format(lang, status:next(), meta:next())
        end)
        :totable()

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    sync_spinners()

    return vim.iter(lines):map(string.len):fold(0, math.max)
end

local function close()
    vim.api.nvim_win_close(win, true)
end

function M.open()
    langs = config.languages
    filter_idx = 0

    if not buf then
        buf = vim.api.nvim_create_buf(false, true)
        local opts = { buf = buf, noremap = true, silent = true }
        vim.keymap.set("n", "q", close, opts)
        vim.keymap.set("n", "<Esc>", close, opts)
        vim.keymap.set("n", "r", M.open, opts)
        vim.keymap.set("n", "i", act.install, opts)
        vim.keymap.set("n", "x", act.remove, opts)
        vim.keymap.set("n", "u", act.update, opts)
        vim.keymap.set("n", "f", cycle_filter, opts)
    end

    local width = M.render()

    if not win or not vim.api.nvim_win_is_valid(win) then
        local w = math.max(#footer + 4, width + 3, 40)
        local h = math.min(#langs + 6, vim.o.lines - 15)
        win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = w,
            height = h,
            style = "minimal",
            border = config.cfg.border,
            row = math.floor((vim.o.lines - h) / 2),
            col = math.floor((vim.o.columns - w) / 2),
            title = title,
            title_pos = "center",
            footer = footer,
            footer_pos = "center",
        })
    end
end

-- Backward compatibility
backport.open = M.open
function backport._act(action)
    act[action]()
end

return M
