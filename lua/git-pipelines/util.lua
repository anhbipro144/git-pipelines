local M = {}

---@return boolean
function M.has_gh()
  return vim.fn.executable 'gh' == 1
end

---@param text unknown
---@return string
function M.trim(text)
  if type(text) ~= 'string' then
    return ''
  end

  return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param text unknown
---@param max_width integer
---@return string
function M.shorten(text, max_width)
  text = M.trim(text)
  if text == '' or max_width <= 0 then
    return ''
  end

  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  if max_width == 1 then
    return '…'
  end

  local char_count = vim.fn.strchars(text)
  local out = ''
  local width = 0

  for index = 0, char_count - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if width + char_width > max_width - 1 then
      break
    end
    out = out .. char
    width = width + char_width
  end

  if out == '' then
    return '…'
  end

  return out .. '…'
end

return M
