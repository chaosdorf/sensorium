# ESP8266-Sensoren mit HDC1080 u.ä.

init.lua differenziert anhand der Chip-ID zwischen den im Clubraum verteilten Boards und ihren verschiedenen Sensoren.
Vor dem Flashen muss wifi.lua erstellt und mit den WLAN-Zugangsdaten befüllt werden:

```
station_cfg.ssid = "..."
station_cfg.pwd = "..."
```

## Flashen

```
nodemcu-uploader.py upload *.lua
```

Anschließend den Resetknopf drücken -- oder für einfacheres Debugging per `screen` o.ä. mit dem Gerät verbinden und `node.restart()` eintippen.
