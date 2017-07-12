local modname = ...
local M = {}
_G[modname] = M

bit = require("bit")

function M.GetReverseByte(byte)
  local bits = 0
  for index = 0, 7 do
    if bit.isset(byte, index) then
      bits = bit.set(bits, 7-index)
    end
  end
  return bits
end

return M
