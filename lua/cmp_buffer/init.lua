local buffer = require('cmp_buffer.buffer')
local maxpq = require('cmp_buffer.maxpq')

---@class cmp_buffer.Options
---@field public keyword_length number
---@field public keyword_pattern string
---@field public get_bufnrs fun(): number[]
---@field public indexing_chunk_size number
---@field public indexing_interval number

---@type cmp_buffer.Options
local defaults = {
  keyword_length = 3,
  keyword_pattern = [[\%(-\?\d\+\%(\.\d\+\)\?\|\h\w*\%([\-]\w*\)*\)]],
  get_bufnrs = function()
    return { vim.api.nvim_get_current_buf() }
  end,
  indexing_chunk_size = 1000,
  indexing_interval = 200,
  max_top_words = 1000,
}

local source = {}

source.new = function()
  local self = setmetatable({}, { __index = source })
  self.buffers = {}
  return self
end

---@return cmp_buffer.Options
source._validate_options = function(_, params)
  local opts = vim.tbl_deep_extend('keep', params.option, defaults)
  vim.validate({
    keyword_length = { opts.keyword_length, 'number' },
    keyword_pattern = { opts.keyword_pattern, 'string' },
    get_bufnrs = { opts.get_bufnrs, 'function' },
    indexing_chunk_size = { opts.indexing_chunk_size, 'number' },
    indexing_interval = { opts.indexing_interval, 'number' },
    max_top_words = { opts.max_top_words, 'number' },
  })
  return opts
end

source.get_keyword_pattern = function(self, params)
  local opts = self:_validate_options(params)
  return opts.keyword_pattern
end

local total_times = {}

source.complete = function(self, params, callback)
  local opts = self:_validate_options(params)

  local processing = false
  local bufs = self:_get_buffers(opts)
  for _, buf in ipairs(bufs) do
    if buf.timer then
      processing = true
      break
    end
  end

  vim.defer_fn(function()
    local start_time_total = vim.loop.hrtime()

    local input = string.sub(params.context.cursor_before_line, params.offset)

    local start_time_rebuild = vim.loop.hrtime()
    for _, buf in ipairs(bufs) do
      local _ = buf:get_words()
    end
    local elapsed_time_rebuild = vim.loop.hrtime() - start_time_rebuild

    local start_time_combine = vim.loop.hrtime()
    local combined_words = {}
    for _, buf in ipairs(bufs) do
      for _, word_list in ipairs(buf:get_words()) do
        for word, word_count in pairs(word_list) do
          local merged_count = combined_words[word]
          if merged_count then
            combined_words[word] = merged_count + word_count
          elseif input ~= word then
            combined_words[word] = word_count
          end
        end
      end
    end
    local elapsed_time_combine = vim.loop.hrtime() - start_time_combine

    local function compare_word_boxes(a, b)
      return combined_words[a] < combined_words[b]
    end

    local start_time_sort_fill = vim.loop.hrtime()
    local queue = maxpq.create(nil)
    queue.greater = function(_, a, b)
      return compare_word_boxes(a, b)
    end
    for word in pairs(combined_words) do
      queue:enqueue(word)
    end
    local elapsed_time_sort_fill = vim.loop.hrtime() - start_time_sort_fill

    local start_time_sort = vim.loop.hrtime()
    local sorted_words = {}
    -- for i = 1, math.min(queue:size(), 1000) do
    for i = 1, queue:size() do
      sorted_words[i] = queue:delMax()
    end
    local elapsed_time_sort = vim.loop.hrtime() - start_time_sort

    local start_time_format = vim.loop.hrtime()
    local items = {}
    for i, word in ipairs(sorted_words) do
      items[i] = {
        label = word,
        -- label = string.format(':%6d %s', word_count, word),
        -- insertText = word,
        dup = 0,
      }
    end
    local elapsed_time_format = vim.loop.hrtime() - start_time_format

    local elapsed_time_total = vim.loop.hrtime() - start_time_total

    if #total_times > 50 then
      table.remove(total_times, 1)
    end
    table.insert(total_times, elapsed_time_total)
    local avg_time = 0
    for i = 1, #total_times do
      avg_time = avg_time + total_times[i]
    end
    avg_time = avg_time / #total_times

    print(string.format('rebuild:%fms(%d%%) combine:%fms(%d%%) sort_fill:%fms(%d%%) sort:%fms(%d%%) format:%fms(%d%%) total:%fms avg:%fms items:#%d', elapsed_time_rebuild / 1e6, elapsed_time_rebuild / elapsed_time_total * 100, elapsed_time_combine / 1e6, elapsed_time_combine / elapsed_time_total * 100, elapsed_time_sort_fill / 1e6, elapsed_time_sort_fill / elapsed_time_total * 100, elapsed_time_sort / 1e6, elapsed_time_sort / elapsed_time_total * 100, elapsed_time_format / 1e6, elapsed_time_format / elapsed_time_total * 100, elapsed_time_total / 1e6, avg_time / 1e6, queue:size()))

    callback({
      items = items,
      isIncomplete = processing or true,
    })
  end, processing and 100 or 0)
end

---@param opts cmp_buffer.Options
source._get_buffers = function(self, opts)
  local buffers = {}
  for _, bufnr in ipairs(opts.get_bufnrs()) do
    if not self.buffers[bufnr] then
      local new_buf = buffer.new(bufnr, opts)
      new_buf.on_close_cb = function()
        self.buffers[bufnr] = nil
      end
      new_buf:index()
      new_buf:watch()
      self.buffers[bufnr] = new_buf
    end
    table.insert(buffers, self.buffers[bufnr])
  end

  return buffers
end

return source
