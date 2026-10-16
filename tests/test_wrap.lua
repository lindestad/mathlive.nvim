local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
child.set_size = function(lines, columns)
  child.o.lines = lines
  child.o.columns = columns
end
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "NONE" })
      child.lua([[vim.opt.rtp:prepend(...)]], { vim.fn.getcwd() })
      child.set_size(20, 30)
      child.lua([[
      vim.o.laststatus=0; vim.o.ruler=false; vim.o.showmode=false; vim.bo.filetype="markdown"
      vim.wo.wrap=true; vim.wo.linebreak=true
      vim.wo.conceallevel=3; vim.wo.concealcursor='nvic'
      local terminal=require('mathlive.image.terminal')
      terminal.supported=true; _G.real_delete_image=terminal.delete_image
      terminal.create_virtual_placement=function(...) end
      terminal.delete_placement=function(...) end; terminal.delete_image=function(...) end
      require('mathlive.image.wrap').setup()
      _G.add_image=function(row, col, width, height)
        local state=require('mathlive.state')
        local buf=vim.api.nvim_get_current_buf()
        local mark=vim.api.nvim_buf_set_extmark(buf,state.ns,row,col,{end_row=row,end_col=col+3})
        local p=setmetatable({buf=buf,id=mark,kind='inline_formula',extmark=mark,eids={},
          img={id=42+mark,size={width=width*9,height=height*18},transmit=function() end},_grid={'image'}},
          require('mathlive.image.placement'))
        state.placements[buf]=state.placements[buf] or {}
        state.placements[buf][mark]={placement=p}
      end
      _G.refresh=function() require('mathlive.image.wrap').refresh(); vim.cmd('redraw!') end
      _G.screen=function()
        vim.cmd('redraw!')
        local rows={}
        local ph=require('mathlive.image.placeholders').placeholder
        for r=1,15 do
          local cells={}
          for c=1,vim.o.columns do
            local s=vim.fn.screenstring(r,c)
            cells[#cells+1]=s:find(ph,1,true) and 'I' or s
          end
          rows[#rows+1]=table.concat(cells):gsub('%s+$','')
        end
        return rows
      end
    ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})
local function lines(value)
  child.api.nvim_buf_set_lines(0, 0, -1, false, value)
end
local function screen()
  return child.lua_get("screen()")
end
local function image_rows(rows)
  local out = {}
  for i, s in ipairs(rows) do
    if s:find("IIII", 1, true) then
      out[#out + 1] = { row = i, col = s:find("IIII", 1, true) }
    end
  end
  return out
end
T["wrapped prose keeps image rows adjacent"] = function()
  lines({ "", "0123456789 0123456789 $x$ trailing words wrap onto another row", "", "end" })
  child.lua("add_image(1,22,4,2); refresh()")
  local rows = screen()
  local images = image_rows(rows)
  eq(#images, 2)
  eq(images[2].row, images[1].row + 1)
  eq(images[1].col, images[2].col)
  eq(table.concat(rows, "\n"):find("trailing words wrap onto", 1, true) ~= nil, true)
end
T["image after a wrap starts within the window"] = function()
  lines({ "", "0123456789 0123456789 0123456789 0123456789 $x$ tail", "", "end" })
  child.lua("add_image(1,44,4,2); refresh()")
  local images = image_rows(screen())
  eq(#images, 2)
  eq(images[1].col <= 27, true)
  eq(images[2].row, images[1].row + 1)
end
T["current source row is revealed without changing the file"] = function()
  local source = { "", "before $x$ after", "", "end" }
  lines(source)
  child.lua("add_image(1,7,4,2); refresh()")
  eq(#image_rows(screen()), 2)
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.lua("refresh()")
  eq(#image_rows(screen()), 0)
  eq(table.concat(screen(), "\n"):find("before $x$ after", 1, true) ~= nil, true)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua("refresh()")
  eq(#image_rows(screen()), 2)
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), source)
end
T["consecutive source rows share a visible anchor"] = function()
  lines({ "", "first $x$ tail", "second $x$ tail", "", "end" })
  child.lua("add_image(1,6,4,2); add_image(2,7,4,2); refresh()")
  local rows = screen()
  eq(#image_rows(rows), 4)
  eq(table.concat(rows, "\n"):find("second IIII tail", 1, true) ~= nil, true)
end
T["first source row renders above the next visible row"] = function()
  lines({ "before $x$ after", "", "end" })
  child.lua("add_image(0,7,4,2)")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.lua("refresh()")
  eq(#image_rows(screen()), 2)
end
T["resizing reflows the image as one box"] = function()
  lines({ "", "0123456789 0123456789 $x$ trailing words wrap onto another row", "", "end" })
  child.lua("add_image(1,22,4,2); refresh()")
  child.set_size(20, 18)
  child.lua("refresh()")
  local images = image_rows(screen())
  eq(#images, 2)
  eq(images[2].row, images[1].row + 1)
  eq(images[1].col, images[2].col)
end
T["two windows get separate namespaces and widths"] = function()
  lines({ "", "0123456789 0123456789 $x$ trailing words wrap onto another row", "", "end" })
  child.lua("add_image(1,22,4,2); refresh()")
  child.set_size(20, 80)
  child.cmd("vsplit")
  child.cmd("vertical resize 30")
  child.lua("refresh()")
  local namespaces = child.lua_get([[(function()
    local out={}
    for name,ns in pairs(vim.api.nvim_get_namespaces()) do
      if name:match('^mathlive.wrap.') then out[#out+1]=vim.api.nvim__ns_get(ns).wins end
    end
    return out
  end)()]])
  eq(#namespaces, 2)
  eq(#namespaces[1], 1)
  eq(#namespaces[2], 1)
  eq(namespaces[1][1] ~= namespaces[2][1], true)
  eq(child.api.nvim_buf_line_count(0), 4)
end
T["Unicode words preserve combining marks and wide characters"] = function()
  child.lua([[
    local wrap=require('mathlive.image.wrap')
    local a={{lines={'界'},width=2,hl='Normal'},{lines={'é'},width=1,hl='Normal'},
      {lines={' '},width=1,hl='Normal',space=true},
      {lines={'AB','CD'},width=2,image=true,hl='Normal'}}
    _G.unicode=wrap.layout(a,4,true)
  ]])
  local result = child.lua_get("unicode")
  eq(result[1][1][1], "界é ")
  eq(result[2][1][1], "AB")
  eq(result[3][1][1], "CD")
end
T["turning wrap off restores native placements"] = function()
  lines({ "", "before $x$ after", "", "end" })
  child.lua([[
    add_image(1,7,4,2)
    local entry=next(require('mathlive.state').placements[vim.api.nvim_get_current_buf()])
    local p=require('mathlive.state').placements[vim.api.nvim_get_current_buf()][entry].placement
    p.img.ensure_sent=function(_,callback) callback(true) end
    refresh()
    vim.wo.wrap=false
    refresh()
  ]])
  local count = child.lua_get([[(function()
    return #vim.api.nvim_buf_get_extmarks(0,require('mathlive.image.placement').ns,0,-1,{})
  end)()]])
  eq(count > 0, true)
  child.lua("vim.wo.wrap=true; refresh()")
  eq(#image_rows(screen()), 2)
end
T["wrapped images have an independent terminal lifetime"] = function()
  lines({ "", "before $x$ after", "", "end" })
  child.lua([[
    add_image(1,7,4,2)
    local state=require('mathlive.state')
    local buf=vim.api.nvim_get_current_buf()
    local key,entry=next(state.placements[buf])
    local p=entry.placement
    _G.deleted=0
    require('mathlive.image.terminal').delete_image=function() deleted=deleted+1 end
    setmetatable(p.img,require('mathlive.image.image'))
    p.img.placements={[p.id]=p}
    p.img.sent=true
    p.img.file='/tmp/test-wrap-image.png'
    refresh()
    p.img:del(p.id)
  ]])
  eq(child.lua_get("deleted"), 1)
  child.lua([[
    require('mathlive.state').placements[vim.api.nvim_get_current_buf()]={}
    refresh()
  ]])
  eq(child.lua_get("deleted"), 2)
end
T["a narrow window scales a wide image without truncating its grid"] = function()
  lines({ "", "$x$", "", "end" })
  child.lua("add_image(1,0,60,4); refresh()")
  local rows = screen()
  local images = {}
  for _, text in ipairs(rows) do
    if text:find("IIII", 1, true) then
      images[#images + 1] = text
    end
  end
  eq(#images, 2)
  eq(#images[1], 30)
  eq(#images[2], 30)
end
T["editing before a formula invalidates the layout cache"] = function()
  lines({ "", "before $x$ after", "", "end" })
  child.lua("add_image(1,7,4,2); refresh()")
  child.api.nvim_buf_set_text(0, 1, 0, 1, 0, { "new " })
  child.lua("refresh()")
  eq(table.concat(screen(), "\n"):find("new before IIII after", 1, true) ~= nil, true)
end
T["tabs expand at the current rendered column"] = function()
  local result = child.lua_get([[(function()
    return require('mathlive.image.wrap').layout({
      {lines={'abc'},width=3,hl='Normal'},
      {lines={'        '},width=8,tab=8,space=true,hl='Normal'},
      {lines={'X'},width=1,hl='Normal'},
    },20,false)
  end)()]])
  eq(result[1][1][1], "abc     X")
end
T["image boxes stay contiguous across varied widths and indentation"] = function()
  child.lua([[
    math.randomseed(41)
    local wrap=require('mathlive.image.wrap')
    for trial=1,200 do
      local width=math.random(12,50)
      local indent=math.random(0,5)
      local atoms,boxes={},{}
      for box=1,4 do
        for i=1,math.random(1,35) do
          atoms[#atoms+1]={lines={'x'},width=1,hl='Normal'}
        end
        atoms[#atoms+1]={lines={' '},width=1,space=true,hl='Normal'}
        local w,h=math.random(2,width),math.random(2,5)
        local ch=string.char(64+box)
        local grid={}
        for y=1,h do grid[y]=string.rep(ch,w) end
        atoms[#atoms+1]={lines=grid,width=w,image=true,hl='Normal'}
        boxes[#boxes+1]={ch=ch,width=w,height=h}
        atoms[#atoms+1]={lines={' '},width=1,space=true,hl='Normal'}
      end
      local result=wrap.layout(atoms,width,trial%2==0,indent)
      local rows={}
      for _,line in ipairs(result) do
        local parts={}
        for _,c in ipairs(line) do parts[#parts+1]=c[1] end
        local text=table.concat(parts)
        assert(#text<=width,string.format('layout exceeded window trial=%d width=%d indent=%d text=%q',trial,width,indent,text)..' bytes='..#text..' cells='..vim.fn.strdisplaywidth(text))
        rows[#rows+1]=text
      end
      for _,box in ipairs(boxes) do
        local positions={}
        for r,text in ipairs(rows) do
          local col=text:find(string.rep(box.ch,box.width),1,true)
          if col then positions[#positions+1]={row=r,col=col} end
        end
        assert(#positions==box.height,'image height changed')
        for i=2,#positions do
          assert(positions[i].row==positions[1].row+i-1,'image rows separated')
          assert(positions[i].col==positions[1].col,'image columns shifted')
        end
      end
    end
  ]])
end
T["retired images are freed after their placeholders leave the screen"] = function()
  lines({ "", "before $x$ after", "", "end" })
  child.lua("add_image(1,7,4,2); refresh()")
  eq(#image_rows(screen()), 2)
  child.lua([[
    local t=require('mathlive.image.terminal')
    t.delete_image=real_delete_image
    _G.retired_count=0
    t.write=function(data)
      if not data:find('a=d',1,true) then return end
      for _,row in ipairs(screen()) do
        assert(not row:find('IIII',1,true),'freed an image while its placeholders were visible')
      end
      retired_count=retired_count+1
    end
    require('mathlive.state').placements[vim.api.nvim_get_current_buf()]={}
    require('mathlive.image.wrap').refresh()
    assert(vim.wait(1000,function() return retired_count>0 end))
  ]])
  eq(child.lua_get("retired_count"), 1)
end
return T
