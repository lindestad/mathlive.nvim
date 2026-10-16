local Terminal = require("mathlive.image.terminal")
local Util = require("mathlive.util")

---@class mathlive.Image
---@field id         integer
---@field file       string
---@field mtime      uv.fs_stat.result.time
---@field size       mathlive.image.Size
---@field sent       boolean
---@field placements table<number, mathlive.image.Placement>
local M = {}
M.__index = M

---@alias mathlive.image.Kind "inline_formula" | "displayed_equation" | "preview_inline_formula" | "preview_displayed_equation"
---@alias mathlive.image.Size { width: integer, height: integer }

local images = {}  ---@type table<string, mathlive.Image?>

---@param file string
---@param unique? boolean
function M.new(file, unique)
  file = vim.fs.normalize(file)
  local fs_stat = vim.uv.fs_stat(file)
  assert(fs_stat, "Image does not exist: " .. file)

  if not unique and images[file] and vim.deep_equal(images[file].mtime, fs_stat.mtime) then
    return images[file]
  end

  local self = setmetatable({}, M)
  self.id = Terminal.generate_id()
  self.file = file
  self.mtime = fs_stat.mtime
  self.size = Util.dim(file)
  self.sent = false
  self.placements = {}

  if not unique then images[file] = self end

  return self
end

-- create the image
function M:send(placement)
  assert(not self.sent, "Image already sent")
  self.sent = true
  self:transmit(self.id, placement)
end

-- Each wrapped window owns a separate terminal image with its own dimensions.
function M:transmit(id, placement)
  if vim.env.SSH_CLIENT or vim.env.SSH_CONNECTION then
    local fd = assert(io.open(self.file, "rb"), "Failed to open file: " .. self.file)
    local data = fd:read("*a")
    fd:close()

    Terminal.transmit(id, data, placement)
  else
    Terminal.transmit_local_png(id, self.file, placement)
  end
end

---@param cb? fun(supported: boolean, created?: boolean)
---@param placement? {id: integer, width: integer, height: integer}
function M:ensure_sent(cb, placement)
  Terminal.detect(function (supported)
    if not supported then
      if cb then cb(false) end
      return
    end

    local created = false
    if not self.sent then
      self:send(placement)
      created = placement ~= nil
    end

    if cb then cb(true, created) end
  end)
end

---@param pid integer
function M:del(pid)
  if not self.placements[pid] then
    return
  end

  Terminal.delete_placement(self.id, pid)
  self.placements[pid] = nil
  if not next(self.placements) then
    Terminal.delete_image(self.id)
    self.sent = false
    if images[self.file] == self then
      images[self.file] = nil
    end
  end
end

return M
