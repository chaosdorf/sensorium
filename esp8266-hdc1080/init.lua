-- nodemcu-release-13-modules-2022-04-12-17-11-54-integer.bin
-- 20 .. 70 mA @ 5V
station_cfg = {}
mqtt_host = "mqtt.chaosdorf.space"

watchdog = tmr.create()
push_timer = tmr.create()
chipid = node.chipid()
hexid = string.format("%06X", chipid)
device_id = "esp8266_" .. hexid
mqtt_prefix = "sensor/" .. device_id
mqttclient = mqtt.Client(device_id, 120)

dofile("wifi.lua")

print("https://wiki.chaosdorf.de/Sensorium")
print("ESP8266 " .. hexid)

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
	gpio.mode(5, gpio.OUTPUT)
	gpio.write(5, 0)
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
	local influx_str = nil
	if have_bme680 then
		local T, P, H, G, QNH = bme680.read()
		if T ~= nil then
			json_str = json_str .. string.format('"temperature_celsius": %d.%02d, "humidity_relpercent": %d.%03d, "pressure_hpa": %d.%02d, "gas_ohm": %d, ', T/100, T%100, H/1000, H%1000, P/100, P%100, G)
			influx_str = string.format("temperature_celsius=%d.%02d,humidity_relpercent=%d.%03d,pressure_hpa=%d.%02d,gas_ohm:%d", T/100, T%100, H/1000, H%1000, P/100, P%100, G)
		end
		bme680.startreadout()
	elseif have_am2320 then
		local am_rh, am_t = am2320.read()
		json_str = json_str .. string.format('"temperature_celsius": %d.%01d, "humidity_relpercent": %d.%01d, ', am_t/10, am_t%10, am_rh/10, am_rh%10)
		influx_str = string.format("temperature_celsius=%d.%01d,humidity_relpercent=%d.%01d", am_t/10, am_t%10, am_rh/10, am_rh%10)
	elseif have_hdc1080 then
		local t, h = hdc1080.read()
		json_str = json_str .. string.format('"temperature_celsius": %.1f, "humidity_relpercent": %.1f, ', t, h)
		influx_str = string.format("temperature_celsius=%.1f,humidity_relpercent=%.1f", t, h)
	elseif have_lm75 then
		local str_temp = read_lm75()
		json_str = json_str .. '"temperature_celsius": ' .. str_temp .. ', '
		influx_str = "temperature_celsius=" .. str_temp
	end
	if have_photoresistor then
		json_str = json_str .. string.format('"brightness_percent": %d.%01d, ', brightness/10, brightness%10)
		influx_str = influx_str .. string.format(",brightness_percent=%d.%01d", brightness/10, brightness%10)
	end
	json_str = json_str .. '"rssi_dbm": ' .. wifi.sta.getrssi() .. '}'
	print("Publishing " .. json_str)
	mqttclient:publish("sensor/" .. device_id .. "/data", json_str, 0, 0, function(client)
		watchdog:start(true)
		if influx_url and influx_attr and influx_str then
			publish_influx(influx_str)
		else
			collectgarbage()
		end
	end)
	push_timer:start()
end

function publish_influx(payload)
	http.post(influx_url, influx_header, "sensorium" .. influx_attr .. " " .. payload, function(code, data)
		collectgarbage()
	end)
end

function log_error()
	print("Network error " .. wifi.sta.status())
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
	mqttclient:on("connect", hass_register)
	mqttclient:on("offline", log_error)
	mqttclient:lwt(mqtt_prefix .. "/state", "offline", 0, 1)
	mqttclient:connect(mqtt_host)
end

function connect_wifi()
	print("WiFi MAC: " .. wifi.sta.getmac())
	print("Connecting to ESSID " .. station_cfg.ssid)
	wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, connect_mqtt)
	wifi.eventmon.register(wifi.eventmon.STA_DHCP_TIMEOUT, log_error)
	wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, log_error)
	wifi.setmode(wifi.STATION)
	wifi.sta.config(station_cfg)
	wifi.sta.connect()
end

function hass_register()
	local publish_queue = {}
	local hass_device = string.format('{"connections":[["mac","%s"]],"identifiers":["%s"],"model":"ESP8266","name":"Sensorium %s","manufacturer":"derf"}', wifi.sta.getmac(), device_id, hexid)
	local hass_entity_base = string.format('"device":%s,"state_topic":"%s/data","expire_after":90', hass_device, mqtt_prefix)
	if have_am2320 or have_bme680 or have_hdc1080 or have_lm75 then
		local hass_temp = string.format('{%s,"name":"Temperature","object_id":"%s_temperature","unique_id":"%s_temperature","device_class":"temperature","unit_of_measurement":"°c","value_template":"{{value_json.temperature_celsius}}"}', hass_entity_base, device_id, device_id)
		table.insert(publish_queue, {"homeassistant/sensor/" .. device_id .. "/temperature/config", hass_temp})
	end
	if have_am2320 or have_bme680 or have_hdc1080 then
		local hass_humi = string.format('{%s,"name":"Humidity","object_id":"%s_humidity","unique_id":"%s_humidity","device_class":"humidity","unit_of_measurement":"%%","value_template":"{{value_json.humidity_relpercent}}"}', hass_entity_base, device_id, device_id)
		table.insert(publish_queue, {"homeassistant/sensor/" .. device_id .. "/humidity/config", hass_humi})
	end
	if have_bme680 then
		local hass_pressure = string.format('{%s,"name":"Pressure","object_id":"%s_pressure","unique_id":"%s_pressure","device_class":"pressure","unit_of_measurement":"hPa","value_template":"{{value_json.pressure_hpa}}"}', hass_entity_base, device_id, device_id)
		table.insert(publish_queue, {"homeassistant/sensor/" .. device_id .. "/pressure/config", hass_pressure})
	end
	if have_photoresistor then
		local hass_brightness = string.format('{%s,"name":"Brightness","object_id":"%s_brightness","unique_id":"%s_brightness","device_class":"illuminance","unit_of_measurement":"%%","value_template":"{{value_json.brightness_percent}}"}', hass_entity_base, device_id, device_id)
		table.insert(publish_queue, {"homeassistant/sensor/" .. device_id .. "/brightness/config", hass_brightness})
	end
	local hass_rssi = string.format('{%s,"name":"RSSI","object_id":"%s_rssi","unique_id":"%s_rssi","device_class":"signal_strength","unit_of_measurement":"dBm","value_template":"{{value_json.rssi_dbm}}","entity_category":"diagnostic"}', hass_entity_base, device_id, device_id)
	table.insert(publish_queue, {"homeassistant/sensor/" .. device_id .. "/rssi/config", hass_rssi})
	hass_mqtt(publish_queue)
end

function hass_mqtt(queue)
	local table_n = table.getn(queue)
	if table_n > 0 then
		local topic = queue[table_n][1]
		local message = queue[table_n][2]
		table.remove(queue)
		mqttclient:publish(topic, message, 0, 1, function(client)
			hass_mqtt(queue)
		end)
	else
		collectgarbage()
		setup_client()
	end
end

watchdog:register(90 * 1000, tmr.ALARM_SEMI, node.restart)
push_timer:register(60 * 1000, tmr.ALARM_SEMI, push_data)
watchdog:start()

connect_wifi()
