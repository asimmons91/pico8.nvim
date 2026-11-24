-- Documentation checks for pico8.nvim.
--
-- Run with:
--   nvim --headless --clean -u NONE -l tests/docs.lua
--
-- Checks local Markdown links and anchors, then verifies that every help tag
-- in doc/pico8.txt is present in doc/tags. External links are not fetched.

local root = vim.env.PICO8_NVIM_ROOT or vim.fn.getcwd()
local errors = {}
local checked_links = 0

local function fail(message)
  errors[#errors + 1] = message
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return table.concat(lines, "\n")
end

local function is_absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil
end

local function file_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

-- GitHub-style heading slugs for the simple headings used in this repository.
local function slugify(text)
  text = text:gsub("`", "")
  text = text:gsub("<[^>]+>", "")
  text = text:lower()
  text = text:gsub("[^%w%s%-_]", "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("%s+", "-")
  text = text:gsub("%-+$", "")
  return text
end

local function markdown_anchors(path)
  local text = read(path)
  if not text then
    return nil
  end
  local anchors = {}
  local seen = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local heading = line:match("^#+%s+(.+)$")
    if heading then
      local slug = slugify(heading)
      local count = seen[slug] or 0
      seen[slug] = count + 1
      if count > 0 then
        slug = slug .. "-" .. count
      end
      anchors[slug] = true
    end
  end
  return anchors
end

local function check_target(source, target)
  target = target:gsub("^%s+", ""):gsub("%s+$", "")
  if target == "" or target:match("^https?://") or target:match("^mailto:") then
    return
  end
  if target:match("^<.*>$") then
    target = target:sub(2, -2)
  end

  local path, anchor = target:match("^([^#]*)#(.*)$")
  if not path then
    path, anchor = target, nil
  end
  if path:match("^%a[%w+.-]*:") and not path:match("^%a:[/\\]") then
    return
  end

  local resolved
  if path == "" or path == "." then
    resolved = source
  elseif is_absolute(path) then
    resolved = vim.fs.normalize(path)
  else
    resolved = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(source), path))
  end

  checked_links = checked_links + 1
  if not file_exists(resolved) then
    fail(("%s: missing link target %s"):format(source, target))
    return
  end
  if not anchor or anchor == "" then
    return
  end
  if not resolved:match("%.md$") then
    return
  end

  local anchors = markdown_anchors(resolved)
  if anchors and not anchors[anchor] then
    fail(("%s: missing anchor #%s in %s"):format(source, anchor, resolved))
  end
end

local function check_file(path)
  local text = read(path)
  if not text then
    fail(("%s: could not read"):format(path))
    return
  end
  for target in text:gmatch("%[[^%]]*%]%(([^%)]+)%)") do
    check_target(path, target)
  end
end

local files = {}
vim.list_extend(files, vim.fn.globpath(root, "*.md", false, true))
vim.list_extend(files, vim.fn.globpath(root .. "/docs", "**/*.md", false, true))
files[#files + 1] = root .. "/doc/pico8.txt"

for _, path in ipairs(files) do
  if file_exists(path) and not path:match("/vendor/") then
    check_file(path)
  end
end

-- GitHub issue forms allow at most ten inputs. Markdown blocks and config.yml
-- do not count as inputs.
for _, path in ipairs(vim.fn.globpath(root .. "/.github/ISSUE_TEMPLATE", "*.yml", false, true)) do
  if not path:match("config%.yml$") then
    local text = read(path)
    local inputs = 0
    if text then
      for line in (text .. "\n"):gmatch("(.-)\n") do
        local kind = line:match("^%s*%-%s*type:%s*(%w+)")
        if kind and kind ~= "markdown" then
          inputs = inputs + 1
        end
      end
    end
    if inputs > 10 then
      fail(("%s: %d issue-form inputs (maximum 10)"):format(path, inputs))
    end
  end
end

local tags_path = root .. "/doc/tags"
local committed_tags = read(tags_path)
if not committed_tags then
  fail("doc/tags is missing; run :helptags doc and commit it")
end

local tags_ok, tags_err = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(root .. "/doc"))
if not tags_ok then
  fail("helptags failed: " .. tostring(tags_err))
end

local help_text = read(root .. "/doc/pico8.txt")
local tags_text = read(tags_path)
if not help_text or not tags_text then
  fail("doc/pico8.txt or doc/tags is missing")
else
  if committed_tags and committed_tags ~= tags_text then
    fail("doc/tags is stale; run :helptags doc and commit it")
  end

  local generated = {}
  for line in (tags_text .. "\n"):gmatch("(.-)\n") do
    local tag = line:match("^([^\t]+)\t")
    if tag then
      generated[tag] = true
    end
  end
  for tag in help_text:gmatch("%*([^%s%*]+)%*") do
    if not generated[tag] then
      fail(("doc/pico8.txt: missing doc/tags entry for %s"):format(tag))
    end
  end

  local runtime = {}
  local runtime_tags = read((vim.env.VIMRUNTIME or "") .. "/doc/tags")
  if runtime_tags then
    for line in (runtime_tags .. "\n"):gmatch("(.-)\n") do
      local tag = line:match("^([^\t]+)\t")
      if tag then
        runtime[tag] = true
      end
    end
  end

  local init = 1
  while true do
    local start, finish, ref = help_text:find("|([^|%s]+)|", init)
    if not start then
      break
    end
    local before = start > 1 and help_text:sub(start - 1, start - 1) or ""
    local after = finish < #help_text and help_text:sub(finish + 1, finish + 1) or ""
    if not before:match("[%w_]") and not after:match("[%w_]") then
      if not generated[ref] and not runtime[ref] then
        fail(("doc/pico8.txt: missing help reference |%s|"):format(ref))
      end
    end
    init = finish + 1
  end
end

if #errors > 0 then
  for _, message in ipairs(errors) do
    vim.api.nvim_err_writeln("docs: " .. message)
  end
  vim.cmd("cquit 1")
end

print(("docs: checked %d files, %d local links; help tags OK"):format(#files, checked_links))
