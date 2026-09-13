local ffi=require('ffi')
pcall(ffi.cdef,'int CreateDirectoryA(const char* p, void* s);')
if FLN and FLN.hook then FLN.hook(false) end
local dst=AshitaCore:GetInstallPath():gsub('\\$','')..'\\addons\\nativefriends\\'
ffi.C.CreateDirectoryA(dst,nil)
local out={}
for _,n in ipairs({'nativefriends.lua','nf_net.lua','nf_record.lua'}) do
  local f=io.open('Z:\\tmp\\nf\\addon\\'..n,'rb'); local d=f:read('*a'); f:close()
  local g=io.open(dst..n,'wb'); g:write(d); g:close(); out[#out+1]=n..':'..#d
end
return dst..' '..table.concat(out,' ')
