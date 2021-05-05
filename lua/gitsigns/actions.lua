local a = require('plenary.async_lib.async')
local await = a.await
local async_void = a.async_void
local scheduler = a.scheduler

local util = require('gitsigns.util')
local signs = require('gitsigns.signs')
local config = require('gitsigns.config').config
local Status = require("gitsigns.status")
local popup = require('gitsigns.popup')

local mk_repeatable = require('gitsigns.repeat').mk_repeatable

local gs_hunks = require('gitsigns.hunks')
local Hunk = gs_hunks.Hunk

local api = vim.api
local current_buf = api.nvim_get_current_buf

local cache = require('gitsigns.cache').cache

local M = {}
















local function get_cursor_hunk(bufnr, hunks)
   bufnr = bufnr or current_buf()
   hunks = hunks or cache[bufnr].hunks

   local lnum = api.nvim_win_get_cursor(0)[1]
   return gs_hunks.find_hunk(lnum, hunks)
end

M.stage_hunk = mk_repeatable(async_void(function()
   local bufnr = current_buf()
   local bcache = cache[bufnr]
   if not bcache then
      return
   end

   if not util.path_exists(bcache.file) then
      print("Error: Cannot stage lines. Please add the file to the working tree.")
      return
   end

   local hunk = get_cursor_hunk(bufnr, bcache.hunks)
   if not hunk then
      return
   end

   await(bcache.git_obj:stage_hunks({ hunk }))

   table.insert(bcache.staged_diffs, hunk)
   bcache.compare_text = nil

   local hunk_signs = gs_hunks.process_hunks({ hunk })

   await(scheduler())






   for lnum, _ in pairs(hunk_signs) do
      signs.remove(bufnr, lnum)
   end
end))

M.reset_hunk = mk_repeatable(function(bufnr, hunk)
   bufnr = bufnr or current_buf()
   hunk = hunk or get_cursor_hunk(bufnr)
   if not hunk then
      return
   end

   local lstart, lend
   if hunk.type == 'delete' then
      lstart = hunk.start
      lend = hunk.start
   else
      local length = vim.tbl_count(vim.tbl_filter(function(l)
         return vim.startswith(l, '+')
      end, hunk.lines))

      lstart = hunk.start - 1
      lend = hunk.start - 1 + length
   end
   api.nvim_buf_set_lines(bufnr, lstart, lend, false, gs_hunks.extract_removed(hunk))
end)

M.reset_buffer = async_void(function()
   local bufnr = current_buf()
   local bcache = cache[bufnr]
   if not bcache then
      return
   end

   local limit = 1000
   for _ = 1, limit do
      if not bcache.hunks[1] then
         return
      end
      M.reset_hunk(bufnr, bcache.hunks[1])
   end
   error('Hit maximum limit of hunks to reset')
end)

M.undo_stage_hunk = mk_repeatable(async_void(function()
   local bufnr = current_buf()
   local bcache = cache[bufnr]
   if not bcache then
      return
   end

   local hunk = table.remove(bcache.staged_diffs)
   if not hunk then
      print("No hunks to undo")
      return
   end

   await(bcache.git_obj:stage_hunks({ hunk }, true))
   bcache.compare_text = nil
   await(scheduler())
   signs.add(config, bufnr, gs_hunks.process_hunks({ hunk }))
end))

M.stage_buffer = async_void(function()
   local bufnr = current_buf()

   local bcache = cache[bufnr]
   if not bcache then
      return
   end


   local hunks = bcache.hunks
   if #hunks == 0 then
      print("No unstaged changes in file to stage")
      return
   end

   if not util.path_exists(bcache.git_obj.file) then
      print("Error: Cannot stage file. Please add it to the working tree.")
      return
   end

   await(bcache.git_obj:stage_hunks(hunks))

   for _, hunk in ipairs(hunks) do
      table.insert(bcache.staged_diffs, hunk)
   end
   bcache.compare_text = nil

   await(scheduler())
   signs.remove(bufnr)
   Status:clear_diff(bufnr)
end)

M.reset_buffer_index = async_void(function()
   local bufnr = current_buf()
   local bcache = cache[bufnr]
   if not bcache then
      return
   end







   local hunks = bcache.staged_diffs
   bcache.staged_diffs = {}

   await(bcache.git_obj:unstage_file())
   bcache.compare_text = nil

   await(scheduler())
   signs.add(config, bufnr, gs_hunks.process_hunks(hunks))
end)

local NavHunkOpts = {}




local function nav_hunk(options)
   local bcache = cache[current_buf()]
   if not bcache then
      return
   end
   local hunks = bcache.hunks
   if not hunks or vim.tbl_isempty(hunks) then
      return
   end
   local line = api.nvim_win_get_cursor(0)[1]

   local wrap = options.wrap ~= nil and options.wrap or vim.o.wrapscan
   local hunk = gs_hunks.find_nearest_hunk(line, hunks, options.forwards, wrap)
   local row = options.forwards and hunk.start or hunk.vend
   if row then

      if row == 0 then
         row = 1
      end
      api.nvim_win_set_cursor(0, { row, 0 })
   end
end

M.next_hunk = function(options)
   options = options or {}
   options.forwards = true
   nav_hunk(options)
end

M.prev_hunk = function(options)
   options = options or {}
   options.forwards = false
   nav_hunk(options)
end

M.preview_hunk = function()
   local hunk = get_cursor_hunk()
   if not hunk then return end

   local _, bufnr = popup.create(hunk.lines, config.preview_config)
   api.nvim_buf_set_option(bufnr, 'filetype', 'diff')
end

M.select_hunk = function()
   local hunk = get_cursor_hunk()
   if not hunk then return end

   vim.cmd('normal! ' .. hunk.start .. 'GV' .. hunk.vend .. 'G')
end

M.blame_line = async_void(function()
   local bufnr = current_buf()
   local bcache = cache[bufnr]
   if not bcache then return end

   local buftext = api.nvim_buf_get_lines(bufnr, 0, -1, false)
   local lnum = api.nvim_win_get_cursor(0)[1]
   local result = await(bcache.git_obj:run_blame(buftext, lnum))

   local date = os.date('%Y-%m-%d %H:%M', tonumber(result['author_time']))
   local lines = {
      ('%s %s (%s):'):format(result.abbrev_sha, result.author, date),
      result.summary,
   }

   await(scheduler())

   local _, pbufnr = popup.create(lines, config.preview_config)

   local p1 = #result.abbrev_sha
   local p2 = #result.author
   local p3 = #date

   local function add_highlight(hlgroup, line, start, length)
      api.nvim_buf_add_highlight(pbufnr, -1, hlgroup, line, start, start + length)
   end

   add_highlight('Directory', 0, 0, p1)
   add_highlight('MoreMsg', 0, p1 + 1, p2)
   add_highlight('Label', 0, p1 + p2 + 2, p3 + 2)
end)

return M
