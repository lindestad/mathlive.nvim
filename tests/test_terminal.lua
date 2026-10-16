local MiniTest = require("mini.test")
local terminal = require("mathlive.image.terminal")
local eq = MiniTest.expect.equality
local output, write
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      output = {}
      write = terminal.write
      terminal.write = function(data)
        output[#output + 1] = data
      end
    end,
    post_case = function()
      terminal.write = write
    end,
  },
})
local function control(data)
  local result = {}
  for k, v in data:match("\027_G([^;\027]+)"):gmatch("(%w+)=([^,]+)") do
    result[k] = v
  end
  return result
end
T["local image uploads create the virtual placement in the same command"] = function()
  terminal.transmit_local_png(42, "/tmp/equation.png", { id = 17, width = 28, height = 2 })
  eq(#output, 1)
  local c = control(output[1])
  eq({ c.a, c.U, c.i, c.p, c.c, c.r, c.C }, { "T", "1", "42", "17", "28", "2", "1" })
end
T["remote image uploads carry placement metadata on the first chunk"] = function()
  terminal.transmit(42, string.rep("x", 8000), { id = 17, width = 28, height = 2 })
  eq(#output > 1, true)
  local first, last = control(output[1]), control(output[#output])
  eq({ first.a, first.U, first.p, first.c, first.r, first.m }, { "T", "1", "17", "28", "2", "1" })
  eq(last.m, "0")
  eq(last.a, nil)
end
T["ordinary uploads retain their original transmission behavior"] = function()
  terminal.transmit(42, "data")
  eq(control(output[1]).a, "t")
end
T["image IDs remain unique after crossing the initial PID partition"] = function()
  local seen = {}
  for _ = 1, 20000 do
    local id = terminal.generate_id()
    assert(id > 0 and id <= 0xFFFFFF)
    assert(not seen[id], "image ID was reused")
    seen[id] = true
  end
end
return T
