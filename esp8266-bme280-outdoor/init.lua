station_cfg = {save=false}
dofile("wifi.lua")
mqtt_host = "mqtt.chaosdorf.space"

chip_id = string.format("%06X", node.chipid())
device_id = "esp8266_" .. chip_id
mqtt_prefix = "sensor/" .. device_id
mqttclient = mqtt.Client(device_id, 120)
sleep_time = 800

adc_mul = 469
adc_div = 102

print("https://wiki.chaosdorf.de/Sensorium")
print("ESP8266 " .. chip_id)

if node.chipid() == 3709664 then
	gpio.mode(5, gpio.OUTPUT)
	gpio.mode(6, gpio.OUTPUT)
	gpio.write(5, 1)
	gpio.write(6, 1)
	i2c.setup(0, 1, 2, i2c.SLOW)
elseif node.chipid() == 6586591 then
	adc_mul = 467
	adc_div = 104
	gpio.mode(6, gpio.OUTPUT)
	gpio.mode(5, gpio.OUTPUT)
	gpio.write(6, 1)
	gpio.write(5, 1)
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
	return adc.read(0) * adc_mul / adc_div
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

	if bat_mv > 4150 then
		sleep_time = 300
	elseif bat_mv < 3600 then
		sleep_time = 1600
	elseif bat_mv < 3900 then
		sleep_time = 800
	elseif bat_mv < 4060 then
		sleep_time = 400
	end

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
	local temp = string.format("%s%d.%01d", Tsgn<0 and "-" or "", T/100, (T%100) / 10)
	local humi = string.format("%d.%01d", H/1000, (H%1000) / 100)
	local pressure = string.format("%d.%03d", P/1000, P%1000)
	local sealevel = string.format("%d.%03d", QNH/1000, QNH%1000)

	local json_str = string.format('{"temperature_celsius":%s,"humidity_relpercent":%s,"pressure_hpa":%s,"pressure_sealevel_hpa":%s,"battery_mv":%d,"battery_percent":%d,"rssi_dbm":%d}', temp, humi, pressure, sealevel, bat_mv, bat_percent, rssi)
	mqttclient:publish(mqtt_prefix .. "/data", json_str, 0, 0, function(client)
		if influx_url and influx_attr then
			publish_influx(temp, humi, pressure, rssi, bat_mv)
		else
			naptime()
		end
	end)
end

function publish_influx(temp, humi, pressure, rssi_dbm, bat_mv)
	http.post(influx_url, nil, string.format("bme280%s temperature_celsius=%s,humidity_relpercent=%s,pressure_hpa=%s", influx_attr, temp, humi, pressure), function(code, data)
		http.post(influx_url, nil, string.format("esp8266%s rssi_dbm=%d,battery_mv=%d", influx_attr, rssi_dbm, bat_mv), function(code, data)
			naptime()
		end)
	end)
end

function hass_register()
	local hass_device = string.format('{"connections":[["mac","%s"]],"identifiers":["%s"],"model":"ESP8266","name":"Sensorium %s","manufacturer":"derf"}', wifi.sta.getmac(), device_id, chip_id)
	local hass_entity_base = string.format('"device":%s,"state_topic":"%s/data","expire_after":1800', hass_device, mqtt_prefix, mqtt_prefix)
	local hass_temperature = string.format('{%s,"name":"Temperature","object_id":"%s_temperature","unique_id":"%s_temperature","device_class":"temperature","unit_of_measurement":"°C","value_template":"{{value_json.temperature_celsius}}"}', hass_entity_base, device_id, device_id)
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
	if sleep_time < 40 then
		print("Waiting")
		go_to_sleep:start(true)
		local next_reading = tmr.create()
		next_reading:register(sleep_time * 1000, tmr.ALARM_SINGLE, publish_reading)
		next_reading:start()
	else
		print("Naptime")
		gpio.write(5, 0)
		gpio.write(6, 0)
		rtctime.dsleep(sleep_time * 1000000)
	end
end

go_to_sleep = tmr.create()
go_to_sleep:register(40 * 1000, tmr.ALARM_SEMI, naptime)
go_to_sleep:start()

connect_wifi()
