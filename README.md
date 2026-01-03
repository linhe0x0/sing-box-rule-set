# sing-box rule-set 

This is a **fully native sing-box** rule-set generation repository:

- ✅ No dependency on v2ray / dat files
- ✅ Uses upstream community rule sources (aligned with Loyalsoldier's data sources)
- ✅ Automatically builds `.srs` files (sing-box native format)
- ✅ Can be directly used by sing-box remote rule-set
- ✅ Regularly updated via GitHub Actions

## Generated rule-sets

This repository generates **1400+ rule-set files** covering various scenarios. The main rule-sets include:

### Core Rule-sets

- **ads.srs** / **category-ads-all.srs** - Ad blocking domain lists
- **private.srs** - Private/local domains (localhost, local, etc.)
- **cn.srs** - Mainland China domains (direct routing)
- **geolocation-cn.srs** - Mainland China geolocation domains
- **geolocation-!cn.srs** - Non-Mainland China domains (proxy routing)
- **category-ai-!cn.srs** / **category-ai-chat-!cn.srs** / **category-ai-cn.srs** - AI service domains (OpenAI, Claude, etc.)

### Service-specific Rule-sets

- **apple.srs** / **apple-cn.srs** - Apple service domains
- **google.srs** / **google-cn.srs** - Google service domains
- **category-games-cn.srs** - Chinese gaming services
- **category-scholar-!cn.srs** - International academic services

### Complete Rule-set List

Browse the [release/srs](https://github.com/linhe0x0/sing-box-rule-set/tree/release/srs) directory to access all available rule-set files.

## Data Sources

This repository integrates data from multiple upstream sources, similar to [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat):

### Domain Lists

- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) - Community-maintained domain lists
- [Loyalsoldier/domain-list-custom](https://github.com/Loyalsoldier/domain-list-custom) - Enhanced domain lists
- [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list) - China-specific domain lists

### Ad Blocking

- AdGuard Mobile Ads filter
- AdGuard DNS filter
- EasyList China + EasyList
- Peter Lowe's Ad server list
- Dan Pollock's hosts file

### Additional Sources

- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) - IP geolocation data
- [Windows Spy Blocker](https://github.com/crazy-max/WindowsSpyBlocker) - Windows telemetry blocking

## Build Process

The build process consists of four stages:

1. **Fetch** (`scripts/fetch.sh`) - Downloads upstream data sources
2. **Normalize** (`scripts/normalize.sh`) - Processes and normalizes domain/IP lists
3. **Compile** (`scripts/compile.sh`) - Compiles text files to `.srs` binary format
4. **Publish** (`scripts/publish.sh`) - Prepares files for release

### Local Build

```bash
# Install sing-box first
# Then run:
make build

# Or step by step:
make fetch      # Fetch upstream sources
make normalize  # Normalize rules
make compile    # Compile to .srs
make publish    # Prepare for release
```

### References

- [sing-box Official Documentation](https://sing-box.sagernet.org/)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) - V2Ray rule-set reference

## Automatic Updates

Rule-sets are automatically updated daily at UTC 00:00 via GitHub Actions.
