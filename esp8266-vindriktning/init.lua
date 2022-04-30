-- 100 mA @ 5V
station_cfg = {}
dofile("wifi.lua")
mqtt_host = "mqtt.chaosdorf.space"

delayed_restart = tmr.create()
chip_id = string.format("%06X", node.chipid())
device_id = "esp8266_" .. chip_id
mqtt_prefix = "sensor/" .. device_id
mqttclient = mqtt.Client(device_id, 120)

print("ESP8266 " .. chip_id)

ledpin = 4
gpio.mode(ledpin, gpio.OUTPUT)
gpio.write(ledpin, 0)

pm1006 = require("pm1006")

pm_values = {}

function log_restart()
	print("Network error " .. wifi.sta.status() .. ". Restarting in 30 seconds.")
	delayed_restart:start()
end

function setup_client()
	print("Connected")
	gpio.write(ledpin, 1)
	publishing = true
	mqttclient:publish(mqtt_prefix .. "/state", "online", 0, 1, function(client)
		publishing = false
	end)
	port = softuart.setup(9600, nil, 2)
	port:on("data", 20, uart_callback)
end

function connect_mqtt()
	print("IP address: " .. wifi.sta.getip())
	print("Connecting to MQTT " .. mqtt_host)
	mqttclient:on("connect", hass_register)
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

function uart_callback(data)
	local pm2_5 = pm1006.parse_frame(data)
	if pm2_5 == nil then
		print("Invalid PM1006 frame")
		return
	else
		table.insert(pm_values, pm2_5)
		if table.getn(pm_values) == 10 then
			local pm_sum = 0
			for i, pm_value in ipairs(pm_values) do
				pm_sum = pm_sum + pm_value
			end
			local pm_int = pm_sum / 10
			local pm_frac = pm_sum % 10
			local json_str = string.format('{"pm2_5_ugm3": %d.%d, "rssi_dbm": %d}', pm_int, pm_frac, wifi.sta.getrssi())
			pm_values = {}
			if not publishing then
				publishing = true
				gpio.write(ledpin, 0)
				mqttclient:publish(mqtt_prefix .. "/data", json_str, 0, 0, function(client)
					publishing = false
					gpio.write(ledpin, 1)
					collectgarbage()
				end)
			end
		end
	end
end

function hass_register()
	local hass_device = string.format('{"connections":[["mac","%s"]],"identifiers":["%s"],"model":"ESP8266 + PM1006","name":"Vindriktning %s","manufacturer":"derf"}', wifi.sta.getmac(), device_id, chip_id)
	local hass_entity_base = string.format('"device":%s,"state_topic":"%s/data","expire_after":90', hass_device, mqtt_prefix)
	local hass_pm2_5 = string.format('{%s,"name":"PM2.5","object_id":"%s_pm2_5","unique_id":"%s_pm2_5","device_class":"pm25","unit_of_measurement":"µg/m³","value_template":"{{value_json.pm2_5_ugm3}}"}', hass_entity_base, device_id, device_id)
	local hass_rssi = string.format('{%s,"name":"RSSI","object_id":"%s_rssi","unique_id":"%s_rssi","device_class":"signal_strength","unit_of_measurement":"dBm","value_template":"{{value_json.rssi_dbm}}","entity_category":"diagnostic"}', hass_entity_base, device_id, device_id)

	delayed_restart:stop()

	mqttclient:publish("homeassistant/sensor/" .. device_id .. "/pm2_5/config", hass_pm2_5, 0, 1, function(client)
		mqttclient:publish("homeassistant/sensor/" .. device_id .. "/rssi/config", hass_rssi, 0, 1, function(client)
			collectgarbage()
			setup_client()
		end)
	end)
end

delayed_restart:register(30 * 1000, tmr.ALARM_SINGLE, node.restart)
delayed_restart:start()

connect_wifi()
