station_cfg = {}
dofile("wifi.lua")
mqtt_host = "mqtt.derf0.net"

chip_id = string.format("%06X", node.chipid())
device_id = "esp8266_" .. chip_id
mqtt_prefix = "sensor/" .. device_id
mqttclient = mqtt.Client(device_id, 120)

print("https://wiki.chaosdorf.de/Sensorium")
print("ESP8266 " .. chip_id)

if node.chipid() == 3709664 then
	gpio.mode(5, gpio.OUTPUT)
	gpio.mode(6, gpio.OUTPUT)
	gpio.write(5, 1)
	gpio.write(6, 1)
	i2c.setup(0, 1, 2, i2c.SLOW)
else
	gpio.mode(6, gpio.OUTPUT)
	gpio.mode(5, gpio.OUTPUT)
	gpio.write(6, 1)
	gpio.write(5, 1)
	i2c.setup(0, 2, 1, i2c.SLOW)
end

if not bme280.setup() then
	print("BME280 setup failed")
end

--   150 kOhm resistor VCC -> A0
-- + 220 kOhm resistor A0 -> ADC
-- + 100 kOhm resistor ADC -> GND
-- -> 4.7V == 1023, 0V == 0
-- -> adc.read(0) / 1023 * (470 / 100) == VCC
-- -> adc.read(0) * 469 / 102 ~= VCC_mV
function get_battery_mv()
	return adc.read(0) * 439 / 102
end

function get_battery_percent(bat_mv)
	if bat_mv > 4160 then
		return 100
	end
	if bat_mv < 3360 then
		return 0
	end
	return (bat_mv - 3360) / 8
end

function connect_mqtt()
	print("IP address: " .. wifi.sta.getip())
	print("Connecting to MQTT " .. mqtt_host)
	mqttclient:on("connect", hass_register)
	mqttclient:connect(mqtt_host)
end

function connect_wifi()
	print("WiFi MAC: " .. wifi.sta.getmac())
	print("Connecting to ESSID " .. station_cfg.ssid)
	wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, connect_mqtt)
	wifi.setmode(wifi.STATION)
	wifi.sta.config(station_cfg)
	wifi.sta.connect()
end

function publish_reading()
	local T, P, H, QNH = bme280.read(68)
	local bat_mv = get_battery_mv()
	local bat_percent = get_battery_percent(bat_mv)
	local rssi = wifi.sta.getrssi()

	if T == nil then
		print("BME280 readout failed")
		local json_str = string.format('{"battery_mv":%d,"battery_percent":%d,"rssi_dbm":%d}', bat_mv, bat_percent, rssi)
		mqttclient:publish(mqtt_prefix .. "/data", json_str, 0, 0, function(client)
			naptime()
		end)
		return
	end

	local Tsgn = (T < 0 and -1 or 1)
	T = Tsgn*T
	local temp = string.format("%s%d.%02d", Tsgn<0 and "-" or "", T/100, T%100)
	local humi = string.format("%d.%03d", H/1000, H%1000)
	local pressure = string.format("%d.%03d", P/1000, P%1000)
	local sealevel = string.format("%d.%03d", QNH/1000, QNH%1000)

	local json_str = string.format('{"temperature_celsius":%s,"humidity_relpercent":%s,"pressure_hpa":%s,"pressure_sealevel_hpa":%s,"battery_mv":%d,"battery_percent":%d,"rssi_dbm":%d}', temp, humi, pressure, sealevel, bat_mv, bat_percent, rssi)
	mqttclient:publish(mqtt_prefix .. "/data", json_str, 0, 0, function(client)
		naptime()
	end)
end

function hass_register()
	local hass_device = string.format('{"connections":[["mac","%s"]],"identifiers":["%s"],"model":"ESP8266","name":"Sensorium %s","manufacturer":"derf"}', wifi.sta.getmac(), device_id, chip_id)
	local hass_entity_base = string.format('"device":%s,"state_topic":"%s/data","expire_after":900', hass_device, mqtt_prefix)
	local hass_temperature = string.format('{%s,"name":"Temperature","object_id":"%s_temperature","unique_id":"%s_temperature","device_class":"temperature","unit_of_measurement":"°c","value_template":"{{value_json.temperature_celsius}}"}', hass_entity_base, device_id, device_id)
	local hass_humidity = string.format('{%s,"name":"Humidity","object_id":"%s_humidity","unique_id":"%s_humidity","device_class":"humidity","unit_of_measurement":"%%","value_template":"{{value_json.humidity_relpercent}}"}', hass_entity_base, device_id, device_id)
	local hass_pressure = string.format('{%s,"name":"Pressure","object_id":"%s_pressure","unique_id":"%s_pressure","device_class":"pressure","unit_of_measurement":"hPa","value_template":"{{value_json.pressure_hpa}}"}', hass_entity_base, device_id, device_id)
	local hass_battery = string.format('{%s,"name":"Battery","object_id":"%s_battery","unique_id":"%s_battery","device_class":"battery","unit_of_measurement":"%%","value_template":"{{value_json.battery_percent}}","entity_category":"diagnostic"}', hass_entity_base, device_id, device_id)
	mqttclient:publish("homeassistant/sensor/" .. device_id .. "/temperature/config", hass_temperature, 0, 1, function(client)
		mqttclient:publish("homeassistant/sensor/" .. device_id .. "/humidity/config", hass_humidity, 0, 1, function(client)
			mqttclient:publish("homeassistant/sensor/" .. device_id .. "/pressure/config", hass_pressure, 0, 1, function(client)
				mqttclient:publish("homeassistant/sensor/" .. device_id .. "/battery/config", hass_battery, 0, 1, function(client)
					publish_reading()
				end)
			end)
		end)
	end)
end

function naptime()
	print("Naptime")
	gpio.write(5, 0)
	gpio.write(6, 0)
	rtctime.dsleep(800 * 1000000)
end

go_to_sleep = tmr.create()
go_to_sleep:register(40 * 1000, tmr.ALARM_SEMI, naptime)
go_to_sleep:start()

connect_wifi()
