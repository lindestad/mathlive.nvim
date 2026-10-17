local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local languages = { "markdown", "markdown_inline", "latex" }
local parser_paths = {}
for _, lang in ipairs(languages) do
  parser_paths[lang] = assert(vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", false)[1])
end

local test_runtime
local T = MiniTest.new_set({
  hooks = {
    pre_case = function ()
      test_runtime = vim.fn.tempname()
      vim.fn.mkdir(test_runtime .. "/parser", "p")
      -- Keep Neovim's Lua modules and queries, but exclude its bundled parsers
      -- as well as parsers installed in the user's data directory.
      assert(vim.uv.fs_symlink(vim.env.VIMRUNTIME .. "/lua", test_runtime .. "/lua", { dir = true }))
      assert(vim.uv.fs_symlink(vim.env.VIMRUNTIME .. "/queries", test_runtime .. "/queries", { dir = true }))
      child.restart({ "-u", "NONE", "--noplugin" })
      child.lua([[
        local repo, runtime, parser_paths = ...
        vim.opt.runtimepath = { repo, runtime }
        vim.opt.packpath = {}
        assert(#vim.api.nvim_get_runtime_file('parser/*', true) == 0)
        require('mathlive.image.terminal').supported = true
        require('mathlive.image.terminal').write = function() end
        _G.install_parser = function(lang)
          assert(vim.uv.fs_copyfile(parser_paths[lang], runtime .. '/parser/' .. lang .. '.so'))
        end
        _G.await_equations = function()
          assert(vim.wait(5000, function()
            local entries = require('mathlive.state').placements[vim.api.nvim_get_current_buf()] or {}
            local count = 0
            for _, entry in pairs(entries) do
              assert(not entry.failed, 'Typst compilation failed')
              if entry.placement and entry.path then count = count + 1 end
            end
            return count == 2
          end), 'math did not render after parsers became available')
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
          '# Math', '', 'Inline $1/(1+x)$ math.', '', '$$', 'sum_(i=1)^n i', '$$', '', 'End.',
        })
      ]], { vim.fn.getcwd(), test_runtime, parser_paths })
    end,
    post_case = function ()
      child.stop()
      vim.fn.delete(test_runtime, "rf")
    end,
  },
})

local function start_markdown()
  child.lua([[
    vim.bo.filetype = 'markdown'
    vim.cmd('runtime plugin/mathlive.lua')
    assert(require('mathlive.state').placements[vim.api.nvim_get_current_buf()] == nil)
  ]])
end

T["startup without parsers does not require a Markdown buffer"] = function ()
  child.lua("vim.cmd('runtime plugin/mathlive.lua')")
  eq(child.lua_get("package.loaded['mathlive'] ~= nil"), true)
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["an open Markdown buffer recovers as all parsers arrive"] = function ()
  start_markdown()
  for _, lang in ipairs(languages) do
    child.lua("install_parser(...)", { lang })
  end
  child.lua("await_equations()")
  child.lua([[
    local entries = require('mathlive.state').placements[vim.api.nvim_get_current_buf()]
    vim.wait(1100)
    assert(entries == require('mathlive.state').placements[vim.api.nvim_get_current_buf()],
      'successful attachment was retried')
  ]])
  eq(child.lua_get("vim.v.errmsg"), "")
end

for _, missing in ipairs(languages) do
  T["waits for the missing " .. missing .. " parser"] = function ()
    for _, lang in ipairs(languages) do
      if lang ~= missing then child.lua("install_parser(...)", { lang }) end
    end
    start_markdown()
    -- More than one retry must remain harmless, including when the root
    -- Markdown parser exists but an injection parser is still missing.
    child.lua("vim.wait(1100)")
    child.lua("install_parser(...)", { missing })
    child.lua("await_equations()")
    eq(child.lua_get("vim.v.errmsg"), "")
  end
end

T["FileType attachment recovers without reopening the buffer"] = function ()
  child.lua("vim.cmd('runtime plugin/mathlive.lua'); vim.bo.filetype = 'markdown'")
  for _, lang in ipairs(languages) do
    child.lua("install_parser(...)", { lang })
  end
  child.lua("await_equations()")
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["recovers when highlighting parsed the document before latex was installed"] = function ()
  child.lua([[
    install_parser('markdown')
    install_parser('markdown_inline')
    vim.bo.filetype = 'markdown'
    vim.treesitter.start()
    vim.treesitter.get_parser():parse(true)
    vim.cmd('runtime plugin/mathlive.lua')
    install_parser('latex')
    await_equations()
  ]])
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["pending attachment is cancelled when the filetype changes"] = function ()
  start_markdown()
  child.lua("vim.bo.filetype = 'text'")
  for _, lang in ipairs(languages) do
    child.lua("install_parser(...)", { lang })
  end
  child.lua("vim.wait(1200)")
  eq(child.lua_get("require('mathlive.state').placements[vim.api.nvim_get_current_buf()] == nil"), true)
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["pending attachment is cancelled when the buffer is deleted"] = function ()
  start_markdown()
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_delete(buf, { force = true })
  for _, lang in ipairs(languages) do
    child.lua("install_parser(...)", { lang })
  end
  child.lua("vim.wait(1200)")
  eq(child.lua_get("require('mathlive.state').placements[...] == nil", { buf }), true)
  eq(child.lua_get("vim.v.errmsg"), "")
end

return T
