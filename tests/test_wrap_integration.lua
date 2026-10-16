local MiniTest = require("mini.test")
local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.set_size(20, 36)
      child.lua([[
      vim.o.laststatus=0; vim.o.ruler=false; vim.o.showmode=false
      vim.wo.wrap=true; vim.wo.linebreak=true
      vim.wo.conceallevel=3; vim.wo.concealcursor='nvic'
      local t=require('mathlive.image.terminal')
      t.supported=true
      t.write=function() end
      require('mathlive').setup({color_hex='#ffaa00'})
      _G.await_equations=function(count)
        assert(vim.wait(5000,function()
          local entries=require('mathlive.state').placements[vim.api.nvim_get_current_buf()] or {}
          local total=0
          for _,e in pairs(entries) do
            if e.failed then error('Typst compilation failed') end
            if e.placement and e.path then total=total+1 end
          end
          return total==count
        end),'equations did not compile')
        require('mathlive.image.wrap').refresh()
      end
    ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})
T["Markdown scanner and Typst compiler feed the wrapped image layout"] = function()
  local source = {
    "# Wrapped math",
    "",
    "A long paragraph before $sum_(i=1)^n i$ with words after it and another $1/(1-x)$ near the end.",
    "",
    "$$",
    "f(x) &= (x+1)^2 \\",
    "&= x^2 + 2x + 1",
    "$$",
    "",
    "End.",
  }
  child.set_lines(source)
  child.bo.filetype = "markdown"
  child.lua("await_equations(3)")
  local result = child.lua_get([[(function()
    local entries=require('mathlive.state').placements[vim.api.nvim_get_current_buf()]
    local count=0
    for _,e in pairs(entries) do
      local size=require('mathlive.util').dim(e.path)
      assert(size.width>0 and size.height>0)
      local owned=0
      for _ in pairs(e.placement.img.placements) do owned=owned+1 end
      assert(owned>=1,'source placement lost its image')
      count=count+1
    end
    return count
  end)()]])
  eq(result, 3)
  eq(child.get_lines(), source)
  child.set_size(20, 22)
  child.lua('require("mathlive.image.wrap").refresh()')
  eq(child.get_lines(), source)
end
T["a live source edit rebuilds the formula and its wrapped placement"] = function()
  child.set_lines({
    "# Math",
    "",
    "A paragraph with $1/(1-x)$ and enough prose to wrap around the rendered fraction.",
    "",
    "End.",
  })
  child.bo.filetype = "markdown"
  child.lua("await_equations(1)")
  local old = child.lua_get(
    [[(function() local _,e=next(require('mathlive.state').placements[vim.api.nvim_get_current_buf()]); return e.hash end)()]]
  )
  child.set_lines({ "A paragraph with $1/(1+x)$ and enough prose to wrap around the rendered fraction." }, 2, 3)
  child.lua("await_equations(1)")
  local changed = child.lua_get(
    [[(function() local _,e=next(require('mathlive.state').placements[vim.api.nvim_get_current_buf()]); return e.hash end)()]]
  )
  eq(changed ~= old, true)
end
T["editing a previewed equation restores rendering after leaving the source"] = function()
  child.set_lines({ "# Math", "", "A paragraph with $1/(1-x)$ and more text.", "", "End." })
  child.bo.filetype = "markdown"
  child.lua("await_equations(1)")
  child.set_cursor(3, 19)
  child.lua('require("mathlive").handle_cursor_moved(vim.api.nvim_get_current_buf())')
  child.set_lines({ "A paragraph with $1/(1+x)$ and more text." }, 2, 3)
  child.lua("vim.wait(200)")
  child.set_cursor(1, 0)
  child.lua([[
    require('mathlive').handle_cursor_moved(vim.api.nvim_get_current_buf())
    await_equations(1)
  ]])
  eq(
    child.lua_get([[(function()
    local _,entry=next(require('mathlive.state').placements[vim.api.nvim_get_current_buf()])
    return {formula=entry.formula,rendered=entry.placement~=nil}
  end)()]]),
    { formula = "1/(1+x)", rendered = true }
  )
end
T["preview files are isolated from other Neovim processes"] = function()
  local other = helpers.new_child_neovim()
  other.setup()
  local one = child.lua_get('require("mathlive.state").preview_path')
  local two = other.lua_get('require("mathlive.state").preview_path')
  other.stop()
  eq(one ~= two, true)
  eq(one:find(tostring(child.fn.getpid()), 1, true) ~= nil, true)
end
return T
