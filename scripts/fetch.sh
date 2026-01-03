#!/usr/bin/env bash
set -e

rm -rf source/upstream
mkdir -p source/upstream

echo "Fetching geoip..."
git clone --depth=1 --branch release --filter=blob:none --sparse https://github.com/Loyalsoldier/geoip source/upstream/geoip
cd source/upstream/geoip && git sparse-checkout set srs && cd -

echo "Fetching domain-list-community..."
git clone --depth=1 https://github.com/v2fly/domain-list-community source/upstream/domain-list-community

echo "Fetching domain-list-custom..."
git clone --depth=1 --branch release https://github.com/Loyalsoldier/domain-list-custom source/upstream/domain-list-custom

echo "Fetching v2ray-rules-dat(hidden branches)..."
git clone --depth=1 --branch hidden https://github.com/Loyalsoldier/v2ray-rules-dat source/upstream/v2ray-rules-dat-hidden

echo "Fetching gfwlist..."
git clone --depth=1 https://github.com/gfwlist/gfwlist source/upstream/gfwlist

echo "Fetching dnsmasq-china-list..."
curl -fsSL https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf \
  -o source/upstream/dnsmasq-china.conf

curl -fsSL https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/google.china.conf \
  -o source/upstream/google.china.conf

curl -fsSL https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/apple.china.conf \
  -o source/upstream/apple.china.conf

echo "Fetching AdGuard filters..."
# AdGuard Mobile Ads
curl -fsSL https://filters.adtidy.org/extension/ublock/filters/224.txt \
  -o source/upstream/adguard-mobile.txt

# AdGuard DNS filter
curl -fsSL https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt \
  -o source/upstream/adguard-dns.txt

# EasyList China + EasyList
curl -fsSL https://easylist-downloads.adblockplus.org/easylistchina+easylist.txt \
  -o source/upstream/easylist.txt

# Peter Lowe's Ad server list
curl -fsSL https://pgl.yoyo.org/adservers/serverlist.php\?hostformat=hosts\&showintro=1\&mimetype=plaintext \
  -o source/upstream/peterlowe.txt

# Dan Pollock's hosts file
curl -fsSL https://someonewhocares.org/hosts/hosts \
  -o source/upstream/danpollock.txt

echo "Fetching Windows Spy Blocker..."
curl -fsSL https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt \
  -o source/upstream/win-spy.txt

curl -fsSL https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/update.txt \
  -o source/upstream/win-update.txt

curl -fsSL https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/extra.txt \
  -o source/upstream/win-extra.txt

echo "Fetch completed!"
