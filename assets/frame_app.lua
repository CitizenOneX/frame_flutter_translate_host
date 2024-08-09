-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data.text is complete text, ready for printing
-- app_data.wip is accumulating chunks and will be copied over to app_data.text when complete
local app_data = { text = "", wip = "" }

-- Frame to phone flags
BATTERY_LEVEL_FLAG = "\x0c"

-- Phone to Frame flags
NON_FINAL_CHUNK_FLAG = 0x0a
FINAL_CHUNK_FLAG = 0x0b


-- every time byte data arrives just extract the data payload from the message
-- and save to the local app_data table so the main loop can pick it up and print it
-- format of [data] (a multi-line text string) is:
-- first digit will be 0x0a/0x0b non-final/final chunk of long text
-- followed by string bytes out to the mtu
function data_handler(data)
    if string.byte(data, 1) == NON_FINAL_CHUNK_FLAG then
        -- non-final chunk
        app_data.wip = app_data.wip .. string.sub(data, 2)
    elseif string.byte(data, 1) == FINAL_CHUNK_FLAG then
        -- final chunk
        app_data.text = app_data.wip .. string.sub(data, 2)
        app_data.wip = ""
    end
end

-- draw the current text on the display
-- Note: For lower latency for text to first appear, we could draw the wip text as it arrives
-- keeping track of horizontal and vertical offsets to continue drawing subsequent packets
function print_text()
    local i = 0
    for line in app_data.text:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                print_text()
                frame.display.show()
                frame.sleep(0.04) -- ~25fps

                -- periodic battery level updates
                local t = frame.time.utc()
                if (last_batt_update == 0 or (t - last_batt_update) > 180) then
                    pcall(frame.bluetooth.send, BATTERY_LEVEL_FLAG .. string.char(math.floor(frame.battery_level())))
                    last_batt_update = t
                end
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04) -- TODO was this too quick, is that why?
            break
        end
    end
end

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(data_handler)

-- run the main app loop
app_loop()