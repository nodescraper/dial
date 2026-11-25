# Dial plugin for Jellyfin

Makes Discovery and the made-for-you mixtapes for the Dial apps, once a day, on your server.

```bash
dotnet build -c Release
```

Copy `bin/Release/net10.0/Dial.Plugin.dll` to `<jellyfin config>/plugins/Dial_0.1.0.0/` and restart Jellyfin.

Full guide: [docs/PLUGIN.md](../docs/PLUGIN.md).
