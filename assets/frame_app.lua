local data = require('data.min')
local battery = require('battery.min')
local plain_text = require('plain_text.min')

-- Phone to Frame flags
TEXT_FLAG = 0x0b

-- register the message parser so it's automatically called when matching data comes in
data.parsers[TEXT_FLAG] = plain_text.parse_plain_text

-- draw the current text on the display
function print_text()
    local i = 0
    for line in data.app_data[TEXT_FLAG].string:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end
end

-- Main app loop
function app_loop()
	-- clear the display
	frame.display.text(" ", 1, 1)
	frame.display.show()
    local last_batt_update = 0

    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = data.process_raw_items()

                if items_ready > 0 then
                    if (data.app_data[TEXT_FLAG] ~= nil and data.app_data[TEXT_FLAG].string ~= nil) then
                        print_text()
                    end
                    frame.display.show()
                end
                frame.sleep(0.04)
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end


        -- periodic battery level updates, 120s
        last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 120)
		frame.sleep(0.1)
    end
end

-- run the main app loop
app_loop()