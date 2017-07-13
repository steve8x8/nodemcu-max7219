--------------------------------------------------------------------------------
-- MAX7229 module for NodeMCU
-- SOURCE: https://github.com/marcelstoer/nodemcu-max7219
-- AUTHOR: marcel at frightanic dot com
-- LICENSE: http://opensource.org/licenses/MIT
--------------------------------------------------------------------------------

-- Set module name as parameter of require
local modname = ...
local M = {}
_G[modname] = M

local bit = require("bit")
--------------------------------------------------------------------------------
-- Local variables
--------------------------------------------------------------------------------
local debug = false
local numberOfModules
local numberOfColumns
-- ESP8266 pin which is connected to CS of the MAX7219
local slaveSelectPin
-- numberOfModules * 8 bytes for the char representation, rightmost byte first
local columns = {}
-- frame buffer lock bit
local fb_lock = true
-- timer to control display
local display_timer = nil
-- scrolling
local scroll_mode = 0
local scroll_delay = 0
-- scrolling index, direction, and countdown
local scroll_offset = 0
local scroll_dir = 0
local scroll_count = 0

local MAX7219_REG_DECODEMODE = 0x09
local MAX7219_REG_INTENSITY = 0x0A
local MAX7219_REG_SCANLIMIT = 0x0B
local MAX7219_REG_SHUTDOWN = 0x0C
local MAX7219_REG_DISPLAYTEST = 0x0F

--------------------------------------------------------------------------------
-- Local/private functions
--------------------------------------------------------------------------------

local function sendByte(module, register, data)
  -- out("module: " .. module .. " register: " .. register .. " data: " .. data)
  -- enable sending data
  gpio.write(slaveSelectPin, gpio.LOW)
  for i = 1, numberOfModules do
    if i == module then
      spi.send(1, register * 256 + data)
    else
      spi.send(1, 0)
    end
  end
  -- make the chip latch data into the registers
  gpio.write(slaveSelectPin, gpio.HIGH)
end

local function numberToTable(number, base, minLen)
  local t = {}
  repeat
    local remainder = number % base
    table.insert(t, 1, remainder)
    number = (number - remainder) / base
  until number == 0
  if #t < minLen then
    for i = 1, minLen - #t do table.insert(t, 1, 0) end
  end
  return t
end

local function rotate(char, rotateleft)
  local matrix = {}
  local newMatrix = {}

  for _, v in ipairs(char) do table.insert(matrix, numberToTable(v, 2, 8)) end

  if rotateleft then
    for i = 8, 1, -1 do
      local s = ""
      for j = 1, 8 do
        s = s .. matrix[j][i]
      end
      table.insert(newMatrix, tonumber(s, 2))
    end
  else
    for i = 1, 8 do
      local s = ""
      for j = 8, 1, -1 do
        s = s .. matrix[j][i]
      end
      table.insert(newMatrix, tonumber(s, 2))
    end
  end
  return newMatrix
end

local function reverseByte(byte)
  local bits = 0
  for index = 0, 7 do
    if bit.isset(byte, index) then
      bits = bit.set(bits, 7-index)
    end
  end
  return bits
end

local function resetScroll()
  -- after filling frame buffer, reset scroll offset and direction
  if     scroll_mode == 1 then -- left
    scroll_offset = #columns or 0
  elseif scroll_mode == 2 then -- right
    scroll_offset = 0
  elseif scroll_mode == 3 then -- bounce, left first
    scroll_offset = #columns or 0
    scroll_dir = -1
  else                         -- no scrolling
    scroll_offset = 0
  end
  scroll_count = scroll_delay
end

-- timer callback function (every 100 ms)
local function sendAll()
  while fb_lock do
    -- dummy loop waiting for frame-buffer lock
  end
  -- scrolling
  local offset
  -- for every module (1 to numberOfModules) send registers 1 - 8
  if scroll_mode == 0 then
    offset = 0
  elseif #(columns or {}) <= numberOfColumns then
    -- scroll only "long" stuff
    offset = 0
  else
    scroll_count = scroll_count - 1
    if scroll_count <= 0 then
      scroll_count = scroll_delay
      scroll_offset = scroll_offset + scroll_dir
      -- beyond frame buffer?
      -- non-bounce scroll restarts
      -- bounce scroll reverses direction
      if     scroll_offset > #columns then
        if scroll_mode ~= 3 then
          scroll_offset = - numberOfColumns
        else
          scroll_dir = - scroll_dir
        end
      elseif scroll_offset < - numberOfColumns then
        if scroll_mode ~= 3 then
          scroll_offset = #columns
        else
          scroll_dir = - scroll_dir
        end
      end
    end
    offset = scroll_offset
  end
  -- for every module (1 to numberOfModules) send registers 1 - 8
  for module = 1, numberOfModules do
    for register = 1, 8 do
      local i = (module-1) * 8 + register + offset
      local byte = columns[i] or 0
      sendByte(module, register, byte)
    end
  end
end

local function commit(what)
  -- lock frame buffer while copying
  fb_lock = true
  -- copy data
  columns = what
  -- reset scrolling
  resetScroll()
  fb_lock = false
  --sendAll()
end

local function out(msg)
  if debug then
    print("[MAX7219] " .. msg)
  end
end

--------------------------------------------------------------------------------
-- Public functions
--------------------------------------------------------------------------------
-- Configures both the SoC and the MAX7219 modules.
-- @param config table with the following keys (* = mandatory)
--               - numberOfModules*
--               - slaveSelectPin*, ESP8266 pin which is connected to CS of the MAX7219
--               - debug
--               - intensity, 0x00 - 0x0F (0 - 15)
--               - scrollmode (0 = off, 1 = left, 2 = right, 3 = bounce)
--               - scrolldelay (one column per n*100 msec)
function M.setup(config)
  local config = config or {}

  numberOfModules = assert(config.numberOfModules, "'numberOfModules' is a mandatory parameter")
  slaveSelectPin = assert(config.slaveSelectPin, "'slaveSelectPin' is a mandatory parameter")
  numberOfColumns = numberOfModules * 8

  if config.debug then debug = config.debug end

  out("number of modules: " .. numberOfModules .. ", SS pin: " .. slaveSelectPin)

  spi.setup(1, spi.MASTER, spi.CPOL_LOW, spi.CPHA_LOW, 16, 8)
  -- Must NOT be done _before_ spi.setup() because that function configures all HSPI* pins for SPI. Hence,
  -- if you want to use one of the HSPI* pins for slave select spi.setup() would overwrite that.
  gpio.mode(slaveSelectPin, gpio.OUTPUT)
  gpio.write(slaveSelectPin, gpio.HIGH)

  for i = 1, numberOfModules do
    sendByte(i, MAX7219_REG_SCANLIMIT, 7)
    sendByte(i, MAX7219_REG_DECODEMODE, 0x00)
    sendByte(i, MAX7219_REG_DISPLAYTEST, 0)
    -- use 1 as default intensity if not configured
    sendByte(i, MAX7219_REG_INTENSITY, config.intensity and config.intensity or 1)
    sendByte(i, MAX7219_REG_SHUTDOWN, 1)
  end

  M.setScroll(config.scrollmode or 0, config.scrolldelay or 0)

  M.clear()

  -- set up display timer
  if display_timer ~= nil then
    display_timer:unregister()
  end
  display_timer = tmr.create()
  display_timer:alarm(100, tmr.ALARM_AUTO, sendAll)
end

-- scrolling setup
function M.setScroll(mode, delay)
  -- start with no offset
  scroll_offset = 0
  -- initial scroll direction
  scroll_mode = mode
  if     scroll_mode == 1 then -- left
    scroll_dir = -1
  elseif scroll_mode == 2 then -- right
    scroll_dir = 1
  elseif scroll_mode == 3 then -- bounce, left first
    scroll_dir = -1
  else                         -- no scrolling
    scroll_dir = 0
  end
  -- delay and countdown
  scroll_delay = delay
  scroll_count = delay
end

function M.clear()
  -- table may have grown beyond physical limit
  local columns = {}
  -- initialize to size of physical device
  for i = 1, numberOfColumns do
    columns[i] = 0
  end
  commit(columns)
end

function M.write(chars, transformation)
  local transformation = transformation or {}

  local c = {}
  for i = 1, #chars do
    local char = chars[i]

    if transformation.rotate ~= nil then
      char = rotate(char, transformation.rotate == "left")
    end

    for k, v in ipairs(char) do
      if transformation.invert == true then
        -- module offset + inverted register + 1
        -- to produce 8, 7 .. 1, 16, 15 ... 9, 24, 23 ...
        local index = ((i - 1) * 8) + 8 - k + 1
        c[index] = reverseByte(v)
      else
        table.insert(c, v)
      end
    end
  end

  commit(c)
end

-- Sets the brightness of the display.
-- intensity: 0x00 - 0x0F (0 - 15)
function M.setIntensity(intensity)
  for i = 1, numberOfModules do
    sendByte(i, MAX7219_REG_INTENSITY, intensity)
  end
end

-- Turns the display on or off.
-- shutdown: true=turn off, false=turn on
function M.shutdown(shutdown)
  local shutdownReg = shutdown and 0 or 1

  for i = 1, numberOfModules do
    sendByte(i, MAX7219_REG_SHUTDOWN, shutdownReg)
  end
end

-- todo: add scrolling support
-- Writes the specified text to the 7-Segment display.
-- If rAlign is true, the text is written right-aligned on the display.
function M.write7segment(text, rAlign)
  local tab = {}
  local lenNoDots = text:gsub("%.", ""):len()

  -- pad with spaces to turn off not required digits
  if (lenNoDots < numberOfColumns) then
    if (rAlign) then
      text = string.rep(" ", numberOfColumns - lenNoDots) .. text
    else
      text = text .. string.rep(" ", numberOfColumns - lenNoDots)
    end
  end

  local wasdot = false
  local font7seg = require("font7seg")

  for i = string.len(text), 1, -1 do
    local currentChar = text:sub(i,i)

    if (currentChar == ".") then
      wasdot = true
    else
      if (wasdot) then
        wasdot = false
        -- take care of the decimal point
        table.insert(tab, font7seg.GetChar(currentChar) + 0x80)
      else
        table.insert(tab, font7seg.GetChar(currentChar))
      end
    end
  end

  package.loaded[font7seg] = nil
  _G[font7seg] = nil
  font7seg = nil

  max7219.write({ tab }, { invert = false })
end

return M
