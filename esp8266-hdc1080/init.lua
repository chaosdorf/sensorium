-- nodemcu-release-13-modules-2022-04-12-17-11-54-integer.bin
-- 20 .. 70 mA @ 5V
station_cfg = {}
dofile("wifi.lua")
mqtt_host = "mqtt.chaosdorf.space"

delayed_restart = tmr.create()
push_timer = tmr.create()
chipid = string.format("%06X", node.chipid())
mqtt_prefix = "sensor/esp8266_" .. chipid
mqttclient = mqtt.Client("dmap_esp8266_" .. chipid, 120)

print("https://wiki.chaosdorf.de/tbd")
print("ESP8266 " .. chipid)

gpio.mode(4, gpio.OUTPUT)
gpio.write(4, 0)

have_am2320 = true
have_bme680 = false
have_hdc1080 = false
have_lm75 = false
have_photoresistor = true
pin_sda = 1
pin_scl = 2

-- 1417026, 482757 -> default
if chipid == 1259750 then
	have_photoresistor = false
	have_am2320 = false
	have_hdc1080 = true
elseif chipid == 1416820 then
	pin_sda = 2
	pin_scl = 1
elseif chipid == 1417132 then
	have_am2320 = false
	have_hdc1080 = true
elseif chipid == 2652641 then
	have_am2320 = false
	have_lm75 = true
	pin_sda = 5
	pin_scl = 6
elseif chipid == 2652764 then
	have_am2320 = false
	have_hdc1080 = true
	pin_sda = 5
	pin_scl = 6
elseif chipid == 2652549 then
	have_am2320 = false
	have_bme680 = true
	pin_sda = 5
	pin_scl = 6
end

i2c.setup(0, pin_sda, pin_scl, i2c.SLOW)

if have_am2320 then
	am2320.setup()
end

if have_bme680 then
	bme680.setup()
end

if have_hdc1080 then
	hdc1080.setup()
end

if have_lm75 then
	i2c.start(0)
	if not i2c.address(0, 0x4f, i2c.TRANSMITTER) then
		print("LM75 not found")
	end
	i2c.write(0, 1, 0)
	i2c.stop(0)
end

function read_lm75()
	local got_error = false
	i2c.start(0)
	if not i2c.address(0, 0x4f, i2c.TRANSMITTER) then
		got_error = true
	end
	i2c.write(0, 0)
	i2c.stop(0)
	i2c.start(0)
	if not i2c.address(0, 0x4f, i2c.RECEIVER) then
		got_error = true
	end
	local ret = i2c.read(0, 2)
	i2c.stop(0)
	if got_error then
		return "null"
	end
	return string.format("%d.%01d", string.byte(ret, 1), string.byte(ret, 2) * 4 / 100)
end

function push_data()
	local brightness = adc.read(0)
	local json_str = '{'
	if have_bme680 then
		local T, P, H, G, QNH = bme680.read()
		if T ~= nil then
			json_str = json_str .. string.format('"temperature_celsius": %d.%02d, "humidity_relpercent": %d.%03d, "pressure_hpa": %d.%02d, "gas_ohm": %d, ', T/100, T%100, H/1000, H%1000, P/100, P%100, G)
		end
		bme680.startreadout()
	elseif have_am2320 then
		local am_rh, am_t = am2320.read()
		json_str = json_str .. string.format('"temperature_celsius": %d.%01d, "humidity_relpercent": %d.%01d, ', am_t/10, am_t%10, am_rh/10, am_rh%10)
	elseif have_hdc1080 then
		local t, h = hdc1080.read()
		json_str = json_str .. string.format('"temperature_celsius": %.1f, "humidity_relpercent": %.1f, ', t, h)
	elseif have_lm75 then
		local str_temp = read_lm75()
		json_str = json_str .. '"temperature_celsius": ' .. str_temp .. ', '
	end
	if have_photoresistor then
		json_str = json_str .. string.format('"brightness_percent": %d.%01d, ', brightness/10, brightness%10)
	end
	json_str = json_str .. '"rssi_dbm": ' .. wifi.sta.getrssi() .. '}'
	print("Publishing " .. json_str)
	mqttclient:publish("sensor/esp8266_" .. chipid .. "/data", json_str, 0, 0, function(client)
		print("Naptime")
		collectgarbage()
	end)
	push_timer:start()
end

function log_restart()
	print("Network error " .. wifi.sta.status() .. ". Restarting in 30 seconds.")
	delayed_restart:start()
end

function setup_client()
	gpio.write(4, 1)
	mqttclient:publish(mqtt_prefix .. "/state", "online", 0, 1, function(client)
		push_data()
	end)
end

function connect_mqtt()
	print("IP address: " .. wifi.sta.getip())
	print("Connecting to MQTT " .. mqtt_host)
	delayed_restart:stop()
	mqttclient:on("connect", setup_client)
	mqttclient:on("connfail", log_restart)
	mqttclient:on("offline", log_restart)
	mqttclient:lwt(mqtt_prefix .. "/state", "offline", 0, 1)
	mqttclient:connect(mqtt_host)
end

function connect_wifi()
	print("WiFi MAC: " .. wifi.sta.getmac())
	print("Connecting to ESSID " .. station_cfg.ssid)
	wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, connect_mqtt)
	wifi.eventmon.register(wifi.eventmon.STA_DHCP_TIMEOUT, log_restart)
	wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, log_restart)
	wifi.setmode(wifi.STATION)
	wifi.sta.config(station_cfg)
	wifi.sta.connect()
end

delayed_restart:register(30 * 1000, tmr.ALARM_SINGLE, node.restart)
push_timer:register(60 * 1000, tmr.ALARM_SEMI, push_data)

delayed_restart:start()

connect_wifi()
