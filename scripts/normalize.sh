#!/usr/bin/env bash
set -e

# ============================================================================
# Global Variables and Cleanup Setup
# ============================================================================

# Track temporary files and directories for cleanup
declare -a TEMP_FILES=()
declare -a TEMP_DIRS=()

# Cleanup function to remove all temporary files
cleanup_temp_files() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    [ -f "$file" ] && rm -f "$file" 2>/dev/null || true
  done
  local dir
  for dir in "${TEMP_DIRS[@]}"; do
    [ -d "$dir" ] && rm -rf "$dir" 2>/dev/null || true
  done
}

# Error handling function
# Usage: error_exit <message> [exit_code]
# Prints error message and exits with specified code (default: 1)
error_exit() {
  local message="$1"
  local exit_code="${2:-1}"
  echo "Error: $message" >&2
  cleanup_temp_files
  exit "$exit_code"
}

# Warning function
# Usage: warning <message>
# Prints warning message without exiting
warning() {
  local message="$1"
  echo "Warning: $message" >&2
}

# Register cleanup trap
trap cleanup_temp_files EXIT INT TERM

rm -rf build/text
mkdir -p build/text

# ============================================================================
# Helper Functions
# ============================================================================

# Validate and extract valid domain names
# This function validates domains according to RFC 1123 standards
# Usage: validate_domains <input_file> <output_file> <min_length> <max_length>
# min_length: minimum domain length (default: 1)
# max_length: maximum domain length (default: 255)
# Returns valid domains matching the length constraints
validate_domains() {
  local input_file="$1"
  local output_file="$2"
  local min_length="${3:-1}"
  local max_length="${4:-255}"

  if [ ! -f "$input_file" ] || [ ! -s "$input_file" ]; then
    touch "$output_file"
    return 0
  fi

  # RFC 1123 compliant domain regex:
  # - Each label: 1-63 chars, alphanumeric or hyphen, cannot start/end with hyphen
  # - Total length: 1-255 chars
  # - At least one dot for FQDN (but we allow TLD-only for some cases)
  # Pattern: ^(?=.{min,max}$)([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*)$
  perl -ne "
    chomp;
    next if /^\s*$/;
    # Match valid domain: 1-255 chars, labels 1-63 chars, alphanumeric/hyphen
    if (/^(?=.{$min_length,$max_length}\$)([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)*)\$/) {
      print \"\$1\\n\";
    }
  " "$input_file" >"$output_file" 2>/dev/null || touch "$output_file"
}

# Extract full domains (FQDN with at least one dot, 3-255 chars)
# This is stricter than validate_domains - requires at least one dot
# Usage: extract_full_domains <input_file> <output_file>
extract_full_domains() {
  local input_file="$1"
  local output_file="$2"

  if [ ! -f "$input_file" ] || [ ! -s "$input_file" ]; then
    touch "$output_file"
    return 0
  fi

  # Full domain pattern: 3-255 chars, at least one dot, valid labels
  perl -ne "
    chomp;
    next if /^\s*$/;
    # Match FQDN: 3-255 chars, at least one dot, valid label structure
    if (/^(?=.{3,255}\$)([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)+)\$/) {
      print \"\$1\\n\";
    }
  " "$input_file" >"$output_file" 2>/dev/null || touch "$output_file"
}

# Sort and deduplicate a file (case-insensitive)
# Usage: sort_and_deduplicate <input_file> <output_file>
# If output_file is empty, outputs to stdout
sort_and_deduplicate() {
  local input_file="$1"
  local output_file="${2:-}"

  if [ ! -f "$input_file" ] || [ ! -s "$input_file" ]; then
    [ -n "$output_file" ] && touch "$output_file" || true
    return 0
  fi

  if [ -n "$output_file" ]; then
    sort --ignore-case -u "$input_file" | grep -v '^[[:space:]]*$' >"$output_file" 2>/dev/null || touch "$output_file"
  else
    sort --ignore-case -u "$input_file" | grep -v '^[[:space:]]*$'
  fi
}

# Recursively expand include statements in domain-list-community files
# Usage: expand_include <file> <data_dir> [visited_set]
expand_include() {
  local file="$1"
  local data_dir="$2"
  local visited="${3:-}"

  # Check if file exists
  if [ ! -f "$file" ]; then
    return 0
  fi

  # Check for circular references
  if [[ "$visited" == *"|$file|"* ]]; then
    echo "Warning: Circular reference detected for $file" >&2
    return 0
  fi
  visited="${visited}|$file|"

  # Process file line by line
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Handle include statements
    if [[ $line =~ ^include:(.+)$ ]]; then
      local include_file="${BASH_REMATCH[1]}"
      local include_path="$data_dir/$include_file"
      expand_include "$include_path" "$data_dir" "$visited"
    else
      # Output the rule as-is (preserving type and attributes)
      echo "$line"
    fi
  done <"$file"
}

# Normalize rules: add domain: prefix to plain domain rules
# Rules with existing prefixes (domain:, full:, regexp:, keyword:) are kept as-is
# Plain domain rules (without prefix) are converted to domain: prefix
# Usage: normalize_rules <input_file_or_stdin> <output_file>
normalize_rules() {
  local input="$1"
  local output="$2"
  local use_stdin=false

  # Check if input is stdin or empty (for pipe input)
  if [ "$input" = "/dev/stdin" ] || [ "$input" = "-" ] || [ -z "$input" ]; then
    use_stdin=true
  elif [ ! -f "$input" ]; then
    # Input file doesn't exist
    touch "$output"
    return 0
  elif [ ! -s "$input" ]; then
    # Input file exists but is empty
    touch "$output"
    return 0
  fi

  {
    if [ "$use_stdin" = true ]; then
      cat
    else
      cat "$input"
    fi
  } | while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and whitespace-only lines
    [[ -z "${line// /}" ]] && continue

    # If line already has a type prefix (domain:, full:, regexp:, keyword:), keep as-is
    if [[ $line =~ ^(domain|full|regexp|keyword): ]]; then
      echo "$line"
    else
      # Plain domain rule - add domain: prefix
      # Skip if the line is empty after trimming
      local trimmed_line="${line#"${line%%[![:space:]]*}"}"
      trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"
      [[ -n "$trimmed_line" ]] && echo "domain:$trimmed_line"
    fi
  done >"$output"
}

# Filter rules based on attributes (Loyalsoldier/domain-list-custom logic)
# Usage: filter_attributes <input_file> <output_file> <exclude_attrs>
# exclude_attrs: comma-separated list of attributes to exclude (e.g., "@ads,@!cn")
# This filters out rules that contain any of the excluded attributes
filter_attributes() {
  local input="$1"
  local output="$2"
  local exclude_attrs="$3"

  if [ ! -f "$input" ] || [ ! -s "$input" ]; then
    touch "$output"
    return 0
  fi

  if [ -z "$exclude_attrs" ]; then
    cp "$input" "$output"
    return 0
  fi

  # Filter out lines containing excluded attributes
  # Attributes appear after the domain/rule, e.g., "domain:example.com @ads @cn"
  # We match attributes that appear as @attr (with space before @ or at start of line after domain)
  local temp_output=$(mktemp)
  TEMP_FILES+=("$temp_output")

  # Convert comma-separated attributes to pattern
  # Each attribute should be matched as @attr (with @ prefix)
  IFS=',' read -ra ATTRS <<<"$exclude_attrs"
  local exclude_pattern=""
  for attr in "${ATTRS[@]}"; do
    # Ensure @ prefix and normalize
    # Remove leading @ if present, then escape all regex special characters
    attr="${attr#@}"  # Remove leading @
    # Escape regex special characters: . * + ? ^ $ { } ( ) | [ ] \
    attr=$(printf '%s\n' "$attr" | sed 's/[.*+?^${}()|[]/\\&/g')
    if [ -z "$exclude_pattern" ]; then
      # Match @attr followed by space, tab, or end of line
      exclude_pattern="@${attr}([[:space:]]|$)"
    else
      exclude_pattern="$exclude_pattern|@${attr}([[:space:]]|$)"
    fi
  done

  # Filter out rules containing excluded attributes
  # Use grep -v to exclude lines matching the pattern
  if [ -n "$exclude_pattern" ]; then
    # Match @attr followed by whitespace or end of line
    grep -vE "($exclude_pattern)" "$input" >"$temp_output" || touch "$temp_output"
    mv "$temp_output" "$output"
  else
    cp "$input" "$output"
  fi
}

# Process a domain list file from domain-list-community
# Usage: process_domain_list <list_name> <exclude_attrs>
process_domain_list() {
  local list_name="$1"
  local exclude_attrs="${2:-}"
  local data_dir="source/upstream/domain-list-community/data"
  local list_file="$data_dir/$list_name"

  if [ ! -f "$list_file" ]; then
    warning "List file not found: $list_file"
    touch "build/text/$list_name.txt"
    return 0
  fi

  echo "Processing $list_name..."

  # Expand includes
  local temp_expanded=$(mktemp)
  TEMP_FILES+=("$temp_expanded")
  expand_include "$list_file" "$data_dir" >"$temp_expanded"

  # Filter attributes and normalize rules in a pipeline to reduce I/O
  # Use pipeline instead of multiple temporary files
  {
    if [ -n "$exclude_attrs" ]; then
      filter_attributes "$temp_expanded" /dev/stdout "$exclude_attrs"
    else
      cat "$temp_expanded"
    fi
  } | normalize_rules /dev/stdin /dev/stdout | \
    sort -u | grep -v '^[[:space:]]*$' >"build/text/$list_name.txt" || touch "build/text/$list_name.txt"

  rm -f "$temp_expanded"
}

# Process cn list (combine cn and geolocation-cn, exclude @ads and @!cn)
process_cn() {
  echo "Processing cn (combining cn and geolocation-cn)..."
  local data_dir="source/upstream/domain-list-community/data"
  local temp_file=$(mktemp)
  TEMP_FILES+=("$temp_file")
  local temp_filtered=$(mktemp)
  TEMP_FILES+=("$temp_filtered")

  # Process cn list (exclude @ads and @!cn)
  if [ -f "$data_dir/cn" ]; then
    expand_include "$data_dir/cn" "$data_dir" | \
      filter_attributes /dev/stdin "$temp_filtered" "@ads,@!cn"
    cat "$temp_filtered" >>"$temp_file"
  fi

  # Process geolocation-cn list (exclude @ads and @!cn)
  if [ -f "$data_dir/geolocation-cn" ]; then
    expand_include "$data_dir/geolocation-cn" "$data_dir" | \
      filter_attributes /dev/stdin "$temp_filtered" "@ads,@!cn"
    cat "$temp_filtered" >>"$temp_file"
  fi

  # Normalize rules: add domain: prefix to plain domain rules
  local temp_normalized=$(mktemp)
  TEMP_FILES+=("$temp_normalized")
  normalize_rules "$temp_file" "$temp_normalized"

  # Sort and deduplicate, remove empty lines
  sort_and_deduplicate "$temp_normalized" "build/text/cn.txt"
  rm -f "$temp_file" "$temp_filtered" "$temp_normalized"
}

# Process geolocation-cn list (exclude @ads and @!cn)
process_geolocation_cn() {
  process_domain_list "geolocation-cn" "@ads,@!cn"
}

# Process geolocation-!cn list (exclude @ads and @cn)
process_geolocation_not_cn() {
  process_domain_list "geolocation-!cn" "@ads,@cn"
}

# Process category lists (no attribute filtering by default)
process_category_list() {
  local category="$1"
  process_domain_list "$category" ""
}

# Generate GFWList domains by parsing local gfwlist.txt file
# Based on gfwlist2dnsmasq.sh core parsing logic
generate_gfwlist_domains() {
  local output_file="$1"
  local gfwlist_file="source/upstream/gfwlist/gfwlist.txt"

  if [ ! -f "$gfwlist_file" ]; then
    warning "gfwlist.txt not found at $gfwlist_file, skipping GFWList generation"
    touch "$output_file"
    return 0
  fi

  # Detect system type for base64 and sed commands
  local base64_decode
  local sed_eres
  local sys_kernel=$(uname -s)
  if [ "$sys_kernel" = "Darwin" ] || [ "$sys_kernel" = "FreeBSD" ]; then
    base64_decode='base64 -D'
    sed_eres='sed -E'
  else
    base64_decode='base64 -d'
    sed_eres='sed -r'
  fi

  # Create temporary files
  local temp_dir=$(mktemp -d)
  TEMP_DIRS+=("$temp_dir")
  local base64_file="$temp_dir/base64.txt"
  local gfwlist_decoded="$temp_dir/gfwlist-decoded.txt"
  local domain_temp="$temp_dir/gfwlist-domains.tmp"

  # Copy gfwlist file and decode base64
  cp "$gfwlist_file" "$base64_file"
  if ! $base64_decode "$base64_file" >"$gfwlist_decoded" 2>/dev/null; then
    warning "Failed to decode gfwlist.txt"
    rm -rf "$temp_dir"
    touch "$output_file"
    return 0
  fi

  # Core parsing patterns from gfwlist2dnsmasq.sh
  local ignore_pattern='^\!|\[|^@@|(https?://){0,1}[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
  local head_filter_pattern='s#^(\|\|?)?(https?://)?##g'
  local tail_filter_pattern='s#/.*$|%2F.*$##g'
  local domain_pattern='([a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+)'
  local handle_wildcard_pattern='s#^(([a-zA-Z0-9]*\*[-a-zA-Z0-9]*)?(\.))?([a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+)(\*[a-zA-Z0-9]*)?#\4#g'

  # Convert gfwlist to domains
  grep -vE "$ignore_pattern" "$gfwlist_decoded" |
    $sed_eres "$head_filter_pattern" |
    $sed_eres "$tail_filter_pattern" |
    grep -E "$domain_pattern" |
    $sed_eres "$handle_wildcard_pattern" >"$domain_temp"

  # Add Google search domains
  printf 'google.com\ngoogle.ad\ngoogle.ae\ngoogle.com.af\ngoogle.com.ag\ngoogle.com.ai\ngoogle.al\ngoogle.am\ngoogle.co.ao\ngoogle.com.ar\ngoogle.as\ngoogle.at\ngoogle.com.au\ngoogle.az\ngoogle.ba\ngoogle.com.bd\ngoogle.be\ngoogle.bf\ngoogle.bg\ngoogle.com.bh\ngoogle.bi\ngoogle.bj\ngoogle.com.bn\ngoogle.com.bo\ngoogle.com.br\ngoogle.bs\ngoogle.bt\ngoogle.co.bw\ngoogle.by\ngoogle.com.bz\ngoogle.ca\ngoogle.cd\ngoogle.cf\ngoogle.cg\ngoogle.ch\ngoogle.ci\ngoogle.co.ck\ngoogle.cl\ngoogle.cm\ngoogle.cn\ngoogle.com.co\ngoogle.co.cr\ngoogle.com.cu\ngoogle.cv\ngoogle.com.cy\ngoogle.cz\ngoogle.de\ngoogle.dj\ngoogle.dk\ngoogle.dm\ngoogle.com.do\ngoogle.dz\ngoogle.com.ec\ngoogle.ee\ngoogle.com.eg\ngoogle.es\ngoogle.com.et\ngoogle.fi\ngoogle.com.fj\ngoogle.fm\ngoogle.fr\ngoogle.ga\ngoogle.ge\ngoogle.gg\ngoogle.com.gh\ngoogle.com.gi\ngoogle.gl\ngoogle.gm\ngoogle.gp\ngoogle.gr\ngoogle.com.gt\ngoogle.gy\ngoogle.com.hk\ngoogle.hn\ngoogle.hr\ngoogle.ht\ngoogle.hu\ngoogle.co.id\ngoogle.ie\ngoogle.co.il\ngoogle.im\ngoogle.co.in\ngoogle.iq\ngoogle.is\ngoogle.it\ngoogle.je\ngoogle.com.jm\ngoogle.jo\ngoogle.co.jp\ngoogle.co.ke\ngoogle.com.kh\ngoogle.ki\ngoogle.kg\ngoogle.co.kr\ngoogle.com.kw\ngoogle.kz\ngoogle.la\ngoogle.com.lb\ngoogle.li\ngoogle.lk\ngoogle.co.ls\ngoogle.lt\ngoogle.lu\ngoogle.lv\ngoogle.com.ly\ngoogle.co.ma\ngoogle.md\ngoogle.me\ngoogle.mg\ngoogle.mk\ngoogle.ml\ngoogle.com.mm\ngoogle.mn\ngoogle.ms\ngoogle.com.mt\ngoogle.mu\ngoogle.mv\ngoogle.mw\ngoogle.com.mx\ngoogle.com.my\ngoogle.co.mz\ngoogle.com.na\ngoogle.com.nf\ngoogle.com.ng\ngoogle.com.ni\ngoogle.ne\ngoogle.nl\ngoogle.no\ngoogle.com.np\ngoogle.nr\ngoogle.nu\ngoogle.co.nz\ngoogle.com.om\ngoogle.com.pa\ngoogle.com.pe\ngoogle.com.pg\ngoogle.com.ph\ngoogle.com.pk\ngoogle.pl\ngoogle.pn\ngoogle.com.pr\ngoogle.ps\ngoogle.pt\ngoogle.com.py\ngoogle.com.qa\ngoogle.ro\ngoogle.ru\ngoogle.rw\ngoogle.com.sa\ngoogle.com.sb\ngoogle.sc\ngoogle.se\ngoogle.com.sg\ngoogle.sh\ngoogle.si\ngoogle.sk\ngoogle.com.sl\ngoogle.sn\ngoogle.so\ngoogle.sm\ngoogle.sr\ngoogle.st\ngoogle.com.sv\ngoogle.td\ngoogle.tg\ngoogle.co.th\ngoogle.com.tj\ngoogle.tk\ngoogle.tl\ngoogle.tm\ngoogle.tn\ngoogle.to\ngoogle.com.tr\ngoogle.tt\ngoogle.com.tw\ngoogle.co.tz\ngoogle.com.ua\ngoogle.co.ug\ngoogle.co.uk\ngoogle.com.uy\ngoogle.co.uz\ngoogle.com.vc\ngoogle.co.ve\ngoogle.vg\ngoogle.co.vi\ngoogle.com.vn\ngoogle.vu\ngoogle.ws\ngoogle.rs\ngoogle.co.za\ngoogle.co.zm\ngoogle.co.zw\ngoogle.cat\n' >>"$domain_temp"

  # Add blogspot domains
  printf 'blogspot.ca\nblogspot.co.uk\nblogspot.com\nblogspot.com.ar\nblogspot.com.au\nblogspot.com.br\nblogspot.com.by\nblogspot.com.co\nblogspot.com.cy\nblogspot.com.ee\nblogspot.com.eg\nblogspot.com.es\nblogspot.com.mt\nblogspot.com.ng\nblogspot.com.tr\nblogspot.com.uy\nblogspot.de\nblogspot.gr\nblogspot.in\nblogspot.mx\nblogspot.ch\nblogspot.fr\nblogspot.ie\nblogspot.it\nblogspot.pt\nblogspot.ro\nblogspot.sg\nblogspot.be\nblogspot.no\nblogspot.se\nblogspot.jp\nblogspot.in\nblogspot.ae\nblogspot.al\nblogspot.am\nblogspot.ba\nblogspot.bg\nblogspot.ch\nblogspot.cl\nblogspot.cz\nblogspot.dk\nblogspot.fi\nblogspot.gr\nblogspot.hk\nblogspot.hr\nblogspot.hu\nblogspot.ie\nblogspot.is\nblogspot.kr\nblogspot.li\nblogspot.lt\nblogspot.lu\nblogspot.md\nblogspot.mk\nblogspot.my\nblogspot.nl\nblogspot.no\nblogspot.pe\nblogspot.qa\nblogspot.ro\nblogspot.ru\nblogspot.se\nblogspot.sg\nblogspot.si\nblogspot.sk\nblogspot.sn\nblogspot.tw\nblogspot.ug\nblogspot.cat\n' >>"$domain_temp"

  # Add twimg.edgesuite.net
  printf 'twimg.edgesuite.net\n' >>"$domain_temp"

  # Sort and deduplicate, extract valid domains (3-255 chars, FQDN)
  sort -u "$domain_temp" | extract_full_domains /dev/stdin "$output_file"

  # Cleanup
  rm -rf "$temp_dir"
}

# Get and add direct domains into temp-direct.txt file
get_direct_domains() {
  local output_file="$1"
  local china_domains_url="source/upstream/dnsmasq-china.conf"
  local custom_direct="source/upstream/domain-list-custom/cn.txt"

  # Extract domains from dnsmasq-china.conf (format: server=/domain/...)
  if [ -f "$china_domains_url" ]; then
    perl -ne '/^server=\/([^\/]+)\// && print "$1\n"' "$china_domains_url" >"$output_file" 2>/dev/null || touch "$output_file"
  else
    touch "$output_file"
  fi

  # Add domains from custom direct list (format: domain:xxx or full:xxx)
  if [ -f "$custom_direct" ]; then
    perl -ne '/^(domain):([^:]+)(\n$|:@.+)/ && print "$2\n"' "$custom_direct" >>"$output_file" 2>/dev/null || true
  fi
}

# Get and add proxy domains into temp-proxy.txt file
get_proxy_domains() {
  local output_file="$1"
  local gfwlist_file="$2"
  local google_domains_url="source/upstream/google.china.conf"
  local apple_domains_url="source/upstream/apple.china.conf"
  local custom_proxy="source/upstream/domain-list-custom/geolocation-!cn.txt"

  # Add all proxy domains in a single pipeline to reduce I/O
  {
    # Add GFWList domains
    [ -f "$gfwlist_file" ] && [ -s "$gfwlist_file" ] && cat "$gfwlist_file" 2>/dev/null || true
    # Add Google China domains
    [ -f "$google_domains_url" ] && perl -ne '/^server=\/([^\/]+)\// && print "$1\n"' "$google_domains_url" 2>/dev/null || true
    # Add Apple China domains
    [ -f "$apple_domains_url" ] && perl -ne '/^server=\/([^\/]+)\// && print "$1\n"' "$apple_domains_url" 2>/dev/null || true
    # Add custom proxy domains (exclude :@cn)
    [ -f "$custom_proxy" ] && grep -Ev ":@cn" "$custom_proxy" | perl -ne '/^(domain):([^:]+)(\n$|:@.+)/ && print "$2\n"' 2>/dev/null || true
  } >"$output_file" 2>/dev/null || touch "$output_file"
}

# Get and add reject domains into temp-reject.txt file
get_reject_domains() {
  local output_file="$1"
  local easylist_url="source/upstream/easylist.txt"
  local adguard_dns_url="source/upstream/adguard-dns.txt"
  local peterlowe_url="source/upstream/peterlowe.txt"
  local danpollock_url="source/upstream/danpollock.txt"

  # Extract from all sources in a single pipeline to reduce I/O
  {
    # Extract from EasyList China + EasyList (format: ||domain^)
    [ -f "$easylist_url" ] && perl -ne '/^\|\|([-_0-9a-zA-Z]+(\.[-_0-9a-zA-Z]+){1,64})\^$/ && print "$1\n"' "$easylist_url" 2>/dev/null || true
    # Extract from AdGuard DNS filter (format: ||domain^)
    [ -f "$adguard_dns_url" ] && perl -ne '/^\|\|([-_0-9a-zA-Z]+(\.[-_0-9a-zA-Z]+){1,64})\^$/ && print "$1\n"' "$adguard_dns_url" 2>/dev/null || true
    # Extract from Peter Lowe's list (format: 127.0.0.1 domain)
    [ -f "$peterlowe_url" ] && perl -ne '/^127\.0\.0\.1\s([-_0-9a-zA-Z]+(\.[-_0-9a-zA-Z]+){1,64})$/ && print "$1\n"' "$peterlowe_url" 2>/dev/null || true
    # Extract from Dan Pollock's hosts file (format: 127.0.0.1 domain)
    [ -f "$danpollock_url" ] && perl -ne '/^127\.0\.0\.1\s([-_0-9a-zA-Z]+(\.[-_0-9a-zA-Z]+){1,64})/ && print "$1\n"' "$danpollock_url" | sed '1d' 2>/dev/null || true
  } | perl -ne 'print if not /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/' >"$output_file" 2>/dev/null || touch "$output_file"
}

# Reserve `full`, `regexp` and `keyword` type of rules from custom lists
reserve_special_rules() {
  local custom_direct="source/upstream/domain-list-custom/cn.txt"
  local custom_proxy="source/upstream/domain-list-custom/geolocation-!cn.txt"
  local direct_reserve="$1"
  local proxy_reserve="$2"

  # Reserve from custom direct
  if [ -f "$custom_direct" ]; then
    perl -ne '/^((full|regexp|keyword):[^:]+)(\n$|:@.+)/ && print "$1\n"' "$custom_direct" |
      sort_and_deduplicate /dev/stdin "$direct_reserve"
  else
    touch "$direct_reserve"
  fi

  # Reserve from custom proxy (exclude :@cn)
  if [ -f "$custom_proxy" ]; then
    grep -Ev ":@cn" "$custom_proxy" | perl -ne '/^((full|regexp|keyword):[^:]+)(\n$|:@.+)/ && print "$1\n"' |
      sort_and_deduplicate /dev/stdin "$proxy_reserve"
  else
    touch "$proxy_reserve"
  fi
}

# Remove redundant domains (deduplicate and sort)
# This function removes duplicate domains and sorts the list
# Note: This is essentially a deduplication function, not a true "redundant removal"
remove_redundant_domains() {
  local list_with_redundant="$1"
  local list_without_redundant="$2"

  if [ ! -f "$list_with_redundant" ] || [ ! -s "$list_with_redundant" ]; then
    touch "$list_without_redundant"
    return 0
  fi

  # Sort and deduplicate the list
  # sort -u removes duplicates and sorts the output
  sort --ignore-case -u "$list_with_redundant" >"$list_without_redundant" 2>/dev/null || touch "$list_without_redundant"
}

# Remove domains from "need-to-remove" lists
# This function removes domains that are in the need-to-remove list from the main list
# Uses comm command for reliable set difference calculation
remove_from_need_to_remove() {
  local need_to_remove_file="$1"
  local list_without_redundant="$2"
  local output_file="$3"

  if [ ! -f "$need_to_remove_file" ] || [ ! -s "$need_to_remove_file" ]; then
    # If no need-to-remove file, use the list as-is
    cp "$list_without_redundant" "$output_file" 2>/dev/null || touch "$output_file"
    return 0
  fi

  if [ ! -f "$list_without_redundant" ] || [ ! -s "$list_without_redundant" ]; then
    touch "$output_file"
    return 0
  fi

  # Use comm to find domains that are NOT in need_to_remove_file
  # comm -23 outputs lines only in first file (list_without_redundant)
  # Both files must be sorted for comm to work correctly
  # Note: comm requires sorted input, so we sort both files
  comm -23 <(sort --ignore-case "$list_without_redundant") \
           <(sort --ignore-case "$need_to_remove_file") \
           >"$output_file" 2>/dev/null || touch "$output_file"
}

# Process and write a list with domain validation and TLD extraction
# Usage: process_list_with_tld <input_file> <output_file> <tld_output_file>
process_list_with_tld() {
  local input_file="$1"
  local output_file="$2"
  local tld_output_file="$3"
  local temp_validated=$(mktemp)
  TEMP_FILES+=("$temp_validated")
  local temp_tld=$(mktemp)
  TEMP_FILES+=("$temp_tld")
  local temp_full_domains=$(mktemp)
  TEMP_FILES+=("$temp_full_domains")

  # Sort and validate domains
  sort_and_deduplicate "$input_file" "$temp_validated"
  validate_domains "$temp_validated" "$temp_tld" 1 255
  normalize_rules "$temp_tld" "$output_file"

  # Generate TLD list (domains that are NOT full FQDNs)
  extract_full_domains "$temp_validated" "$temp_full_domains"
  sort_and_deduplicate "$temp_full_domains" /dev/stdout | \
    comm -23 "$temp_validated" - | \
    sort_and_deduplicate /dev/stdin "$tld_output_file"

  rm -f "$temp_validated" "$temp_tld" "$temp_full_domains"
}

# Process additional lists (china-list, google-cn, apple-cn, gfw, greatfire, win-*)
# Usage: process_additional_lists <gfwlist_file> <temp_dir>
process_additional_lists() {
  local gfwlist_file="$1"
  local temp_dir="$2"
  local china_domains_url="source/upstream/dnsmasq-china.conf"
  local google_domains_url="source/upstream/google.china.conf"
  local apple_domains_url="source/upstream/apple.china.conf"
  local data_dir="source/upstream/domain-list-community/data"
  local win_spy_url="source/upstream/win-spy.txt"
  local win_update_url="source/upstream/win-update.txt"
  local win_extra_url="source/upstream/win-extra.txt"

  echo "  Creating additional lists..."

  # Create china-list.txt (from dnsmasq-china.conf)
  if [ -f "$china_domains_url" ]; then
    local temp_china=$(mktemp)
    TEMP_FILES+=("$temp_china")
    perl -ne '/^server=\/([^\/]+)\// && print "$1\n"' "$china_domains_url" |
      sort_and_deduplicate /dev/stdin "$temp_china"
    normalize_rules "$temp_china" "build/text/china-list.txt"
    rm -f "$temp_china"
  else
    touch "build/text/china-list.txt"
  fi

  # Create google-cn.txt (from google.china.conf, with full: prefix)
  if [ -f "$google_domains_url" ]; then
    perl -ne '/^server=\/([^\/]+)\// && print "full:$1\n"' "$google_domains_url" |
      sort_and_deduplicate /dev/stdin "build/text/google-cn.txt"
  else
    touch "build/text/google-cn.txt"
  fi

  # Create apple-cn.txt (from apple.china.conf, with full: prefix)
  if [ -f "$apple_domains_url" ]; then
    perl -ne '/^server=\/([^\/]+)\// && print "full:$1\n"' "$apple_domains_url" |
      sort_and_deduplicate /dev/stdin "build/text/apple-cn.txt"
  else
    touch "build/text/apple-cn.txt"
  fi

  # Create gfw.txt (from gfwlist file generated in Step 1)
  if [ -f "$gfwlist_file" ] && [ -s "$gfwlist_file" ]; then
    local temp_gfw=$(mktemp)
    TEMP_FILES+=("$temp_gfw")
    extract_full_domains "$gfwlist_file" "$temp_gfw"
    sort_and_deduplicate "$temp_gfw" "$temp_gfw"
    normalize_rules "$temp_gfw" "build/text/gfw.txt"
    rm -f "$temp_gfw"
  else
    touch "build/text/gfw.txt"
  fi

  # Create greatfire.txt (from domain-list-community/data/greatfire if exists)
  if [ -f "$data_dir/greatfire" ]; then
    local temp_greatfire=$(mktemp)
    TEMP_FILES+=("$temp_greatfire")
    expand_include "$data_dir/greatfire" "$data_dir" >"$temp_greatfire"
    normalize_rules "$temp_greatfire" "build/text/greatfire.txt"
    sort_and_deduplicate "build/text/greatfire.txt" "build/text/greatfire.txt.tmp" && \
      mv "build/text/greatfire.txt.tmp" "build/text/greatfire.txt" || touch "build/text/greatfire.txt"
    rm -f "$temp_greatfire"
  else
    touch "build/text/greatfire.txt"
  fi

  # Create win-spy.txt, win-update.txt, win-extra.txt (from Windows Spy Blocker)
  for win_file in "win-spy:$win_spy_url" "win-update:$win_update_url" "win-extra:$win_extra_url"; do
    local win_name="${win_file%%:*}"
    local win_url="${win_file#*:}"
    if [ -f "$win_url" ]; then
      local temp_win=$(mktemp)
      TEMP_FILES+=("$temp_win")
      grep "0.0.0.0" "$win_url" | awk '{print $2}' |
        sort_and_deduplicate /dev/stdin "$temp_win"
      normalize_rules "$temp_win" "build/text/$win_name.txt"
      rm -f "$temp_win"
    else
      touch "build/text/$win_name.txt"
    fi
  done
}

# This replaces the original process_cn, process_geolocation_cn, process_geolocation_not_cn
process_main_lists() {
  echo "Processing main lists..."

  local temp_dir=$(mktemp -d)
  TEMP_DIRS+=("$temp_dir")
  local gfwlist_file="$temp_dir/gfwlist-domains.txt"
  local temp_direct="$temp_dir/temp-direct.txt"
  local temp_proxy="$temp_dir/temp-proxy.txt"
  local temp_reject="$temp_dir/temp-reject.txt"
  local direct_reserve="$temp_dir/direct-reserve.txt"
  local proxy_reserve="$temp_dir/proxy-reserve.txt"
  local direct_list_redundant="$temp_dir/direct-list-with-redundant"
  local proxy_list_redundant="$temp_dir/proxy-list-with-redundant"
  local reject_list_redundant="$temp_dir/reject-list-with-redundant"
  local direct_list_clean="$temp_dir/direct-list-without-redundant"
  local proxy_list_clean="$temp_dir/proxy-list-without-redundant"
  local reject_list_clean="$temp_dir/reject-list-without-redundant"
  local temp_cn="$temp_dir/temp-cn.txt"
  local temp_geolocation_not_cn="$temp_dir/temp-geolocation-!cn.txt"
  local temp_category_ads_all="$temp_dir/temp-category-ads-all.txt"

  # Step 1: Generate GFWList domains
  echo "  Generating GFWList domains..."
  generate_gfwlist_domains "$gfwlist_file"

  # Step 2: Get direct domains
  echo "  Getting direct domains..."
  get_direct_domains "$temp_direct"

  # Step 3: Get proxy domains
  echo "  Getting proxy domains..."
  get_proxy_domains "$temp_proxy" "$gfwlist_file"

  # Step 4: Get reject domains
  echo "  Getting reject domains..."
  get_reject_domains "$temp_reject"

  # Step 5: Reserve special rules (full, regexp, keyword)
  echo "  Reserving special rules..."
  reserve_special_rules "$direct_reserve" "$proxy_reserve"

  # Step 6: Add domains from hidden branch
  echo "  Adding domains from hidden branch..."
  local hidden_dir="source/upstream/v2ray-rules-dat-hidden"
  if [ -f "$hidden_dir/proxy.txt" ]; then
    cat "$hidden_dir/proxy.txt" >>"$temp_proxy" 2>/dev/null || true
  fi
  if [ -f "$hidden_dir/direct.txt" ]; then
    cat "$hidden_dir/direct.txt" >>"$temp_direct" 2>/dev/null || true
  fi
  if [ -f "$hidden_dir/reject.txt" ]; then
    cat "$hidden_dir/reject.txt" >>"$temp_reject" 2>/dev/null || true
  fi

  # Step 7: Sort and generate redundant lists
  # Use centralized sort function to avoid code duplication
  echo "  Sorting and generating lists..."
  sort_and_deduplicate "$temp_proxy" "$proxy_list_redundant"
  sort_and_deduplicate "$temp_direct" "$direct_list_redundant"
  sort_and_deduplicate "$temp_reject" "$reject_list_redundant"

  # Step 8: Remove redundant domains
  echo "  Removing redundant domains..."
  remove_redundant_domains "$direct_list_redundant" "$direct_list_clean"
  remove_redundant_domains "$proxy_list_redundant" "$proxy_list_clean"
  remove_redundant_domains "$reject_list_redundant" "$reject_list_clean"

  # Step 9: Remove domains from need-to-remove lists
  echo "  Removing domains from need-to-remove lists..."
  local hidden_dir="source/upstream/v2ray-rules-dat-hidden"
  remove_from_need_to_remove "$hidden_dir/direct-need-to-remove.txt" "$direct_list_clean" "$temp_cn"
  remove_from_need_to_remove "$hidden_dir/proxy-need-to-remove.txt" "$proxy_list_clean" "$temp_geolocation_not_cn"
  remove_from_need_to_remove "$hidden_dir/reject-need-to-remove.txt" "$reject_list_clean" "$temp_category_ads_all"

  # Step 10: Write lists to output directory with domain validation
  echo "  Writing final lists..."
  process_list_with_tld "$temp_cn" "build/text/cn.txt" "build/text/direct-tld-list.txt"
  process_list_with_tld "$temp_geolocation_not_cn" "build/text/geolocation-!cn.txt" "build/text/proxy-tld-list.txt"
  process_list_with_tld "$temp_category_ads_all" "build/text/ads.txt" "build/text/reject-tld-list.txt"

  # Step 11: Add reserved rules back
  echo "  Adding reserved rules back..."
  if [ -f "$direct_reserve" ] && [ -s "$direct_reserve" ]; then
    cat "$direct_reserve" >>"build/text/cn.txt" 2>/dev/null || true
  fi
  if [ -f "$proxy_reserve" ] && [ -s "$proxy_reserve" ]; then
    cat "$proxy_reserve" >>"build/text/geolocation-!cn.txt" 2>/dev/null || true
  fi

  # Final sort and deduplicate (using centralized function)
  sort_and_deduplicate "build/text/cn.txt" "build/text/cn.txt.tmp" && \
    mv "build/text/cn.txt.tmp" "build/text/cn.txt" || touch "build/text/cn.txt"
  sort_and_deduplicate "build/text/geolocation-!cn.txt" "build/text/geolocation-!cn.txt.tmp" && \
    mv "build/text/geolocation-!cn.txt.tmp" "build/text/geolocation-!cn.txt" || touch "build/text/geolocation-!cn.txt"
  sort_and_deduplicate "build/text/ads.txt" "build/text/ads.txt.tmp" && \
    mv "build/text/ads.txt.tmp" "build/text/ads.txt" || touch "build/text/ads.txt"

  # Step 12: Create additional lists (china-list, google-cn, apple-cn, gfw, greatfire, win-*)
  process_additional_lists "$gfwlist_file" "$temp_dir"

  # Cleanup (trap will also handle this, but explicit cleanup is good practice)
  rm -rf "$temp_dir"

  echo "  Main lists processing completed!"
}

# ============================================================================
# Main Processing
# ============================================================================

echo "Starting normalization process..."

# Check if domain-list-community exists
if [ ! -d "source/upstream/domain-list-community/data" ]; then
  error_exit "domain-list-community data directory not found! Please run 'make fetch' first." 1
fi

process_main_lists

# Process geolocation-cn list (exclude @ads and @!cn)
process_geolocation_cn

# Process category lists
echo "Processing category lists..."
for category_file in source/upstream/domain-list-community/data/category-*; do
  if [ -f "$category_file" ]; then
    category_name=$(basename "$category_file")
    process_category_list "$category_name"
  fi
done

# Process common service lists
echo "Processing service lists..."
common_services=(
  "google" "github" "telegram" "facebook" "twitter" "youtube"
  "netflix" "instagram" "whatsapp" "discord" "reddit" "pinterest"
  "tiktok" "spotify" "amazon" "microsoft" "apple" "adobe"
  "dropbox" "onedrive" "cloudflare" "fastly" "akamai"
)

for service in "${common_services[@]}"; do
  if [ -f "source/upstream/domain-list-community/data/$service" ]; then
    process_category_list "$service"
  fi
done

# Process all other lists in data directory
echo "Processing other domain lists..."
for list_file in source/upstream/domain-list-community/data/*; do
  if [ -f "$list_file" ]; then
    list_name=$(basename "$list_file")
    # Skip if already processed
    if [[ ! "$list_name" =~ ^(cn|geolocation-cn|geolocation-!cn)$ ]] &&
      [[ ! "$list_name" =~ ^category- ]] &&
      [[ ! " ${common_services[@]} " =~ " ${list_name} " ]]; then
      process_category_list "$list_name"
    fi
  fi
done

# Copy and merge custom files from source/custom to build/text
# If target file exists, merge and deduplicate
process_custom_files() {
  echo "Processing custom files from source/custom..."
  local custom_dir="source/custom"
  local build_text_dir="build/text"

  if [ ! -d "$custom_dir" ]; then
    warning "Custom directory not found: $custom_dir"
    return 0
  fi

  # Process each txt file in custom directory
  for custom_file in "$custom_dir"/*.txt; do
    if [ -f "$custom_file" ]; then
      local filename=$(basename "$custom_file")
      local target_file="$build_text_dir/$filename"

      # Normalize the custom file first
      local temp_normalized=$(mktemp)
      TEMP_FILES+=("$temp_normalized")
      normalize_rules "$custom_file" "$temp_normalized"

      if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        # File exists, merge and deduplicate in a single pipeline
        echo "  Merging $filename..."
        {
          cat "$target_file"
          cat "$temp_normalized"
        } | sort_and_deduplicate /dev/stdin "$target_file.tmp"
        mv "$target_file.tmp" "$target_file"
      else
        # File doesn't exist, just copy
        echo "  Copying $filename..."
        cp "$temp_normalized" "$target_file"
      fi

      rm -f "$temp_normalized"
    fi
  done

  echo "  Custom files processing completed!"
}

process_custom_files

echo "Normalization completed!"
echo "Text files generated in build/text/"
echo "Total files: $(ls -1 build/text/*.txt 2>/dev/null | wc -l | tr -d ' ')"

# ============================================================================
# Convert TXT files to JSON format
# ============================================================================

echo ""
echo "Starting JSON conversion process..."

# Ensure output directory exists
rm -rf build/json
mkdir -p build/json

# Get CPU core count for parallel processing
if command -v nproc >/dev/null 2>&1; then
  PARALLEL_JOBS=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  PARALLEL_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo "8")
else
  PARALLEL_JOBS=8
fi

# Process a single file using awk to generate JSON
# Parameters: $1 = input txt file path
process_file_with_awk() {
  local txt_file="$1"
  local filename=$(basename -- "$txt_file")
  local filename_noext="${filename%.*}"
  local json_file="build/json/${filename_noext}.json"

  # Use awk to process file and generate JSON
  awk '
  # JSON escape function (must be defined before BEGIN)
  function json_escape(str) {
    if (str !~ /[\\"\\n\\r\\t]/) {
      return str
    }
    gsub(/\\/, "\\\\", str)
    gsub(/"/, "\\\"", str)
    gsub(/\n/, "\\n", str)
    gsub(/\r/, "\\r", str)
    gsub(/\t/, "\\t", str)
    return str
  }

  BEGIN {
    # Initialize arrays
    domain_suffix_count = 0
    domain_full_count = 0
    regex_count = 0
    keyword_count = 0
  }

  {
    # Trim leading and trailing whitespace
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)

    # Skip empty lines and comment lines
    if ($0 == "" || $0 ~ /^[[:space:]]*#/) {
      next
    }

    # Remove attributes (@cn, @ads, etc.), take the part before the first @ or space
    rule_value = $0
    if (match(rule_value, /[@ ]/)) {
      rule_value = substr(rule_value, 1, RSTART - 1)
    }
    gsub(/[[:space:]]+$/, "", rule_value)

    if (rule_value == "") {
      next
    }

    # Parse different types of rules according to sing-box rule-set format
    # Rule type mapping:
    #   domain:  -> domain_suffix (matches domain and all subdomains, e.g., "example.com" matches "example.com", "www.example.com", "sub.example.com")
    #   full:    -> domain (exact match only, e.g., "example.com" matches only "example.com", not subdomains)
    #   regexp:  -> domain_regex (regular expression matching)
    #   keyword: -> domain_keyword (keyword matching, matches if domain contains the keyword)
    #   (no prefix) -> domain_suffix (default behavior, matches domain and subdomains)
    #
    # This mapping follows sing-box best practices:
    #   - domain_suffix is preferred for most cases (faster than regex, covers subdomains)
    #   - domain (exact) is used only when subdomain matching is not desired
    #   - regexp and keyword are used for complex matching patterns
    if (rule_value ~ /^domain:/) {
      # domain: rule - use domain_suffix to match domain and all subdomains
      # This is the most common and performant rule type in sing-box
      value = substr(rule_value, 8)  # Skip "domain:"
      value = json_escape(value)
      domain_suffix[domain_suffix_count++] = "\"" value "\""
    } else if (rule_value ~ /^full:/) {
      # full: rule (uses domain for exact match in sing-box)
      # Use this when you want to match only the exact domain, not subdomains
      value = substr(rule_value, 6)  # Skip "full:"
      value = json_escape(value)
      domain_full[domain_full_count++] = "\"" value "\""
    } else if (rule_value ~ /^regexp:/) {
      # regexp: rule - regular expression matching
      # Slower than domain_suffix/domain, use only when necessary
      value = substr(rule_value, 8)  # Skip "regexp:"
      value = json_escape(value)
      regex[regex_count++] = "\"" value "\""
    } else if (rule_value ~ /^keyword:/) {
      # keyword: rule - keyword matching
      # Matches if domain contains the keyword anywhere
      value = substr(rule_value, 9)  # Skip "keyword:"
      value = json_escape(value)
      keyword[keyword_count++] = "\"" value "\""
    } else {
      # Rule without prefix, default to domain_suffix (match domain and subdomains)
      # This is the recommended default for best performance and coverage
      value = json_escape(rule_value)
      domain_suffix[domain_suffix_count++] = "\"" value "\""
    }
  }

  END {
    # Build rule object
    rule_parts = ""
    comma_needed = 0

    if (domain_suffix_count > 0) {
      domain_suffix_str = domain_suffix[0]
      for (i = 1; i < domain_suffix_count; i++) {
        domain_suffix_str = domain_suffix_str "," domain_suffix[i]
      }
      if (comma_needed) rule_parts = rule_parts ","
      rule_parts = rule_parts "\"domain_suffix\": [" domain_suffix_str "]"
      comma_needed = 1
    }

    if (domain_full_count > 0) {
      domain_full_str = domain_full[0]
      for (i = 1; i < domain_full_count; i++) {
        domain_full_str = domain_full_str "," domain_full[i]
      }
      if (comma_needed) rule_parts = rule_parts ","
      rule_parts = rule_parts "\"domain\": [" domain_full_str "]"
      comma_needed = 1
    }

    if (regex_count > 0) {
      regex_str = regex[0]
      for (i = 1; i < regex_count; i++) {
        regex_str = regex_str "," regex[i]
      }
      if (comma_needed) rule_parts = rule_parts ","
      rule_parts = rule_parts "\"domain_regex\": [" regex_str "]"
      comma_needed = 1
    }

    if (keyword_count > 0) {
      keyword_str = keyword[0]
      for (i = 1; i < keyword_count; i++) {
        keyword_str = keyword_str "," keyword[i]
      }
      if (comma_needed) rule_parts = rule_parts ","
      rule_parts = rule_parts "\"domain_keyword\": [" keyword_str "]"
      comma_needed = 1
    }

    # If no rules, create an empty rule object
    if (rule_parts == "") {
      rule_object = "{}"
    } else {
      rule_object = "{" rule_parts "}"
    }

    # Generate complete JSON content
    printf "{\n  \"version\": 1,\n  \"rules\": [\n    %s\n  ]\n}", rule_object
  }
  ' "$txt_file" >"$json_file"

  # Show processing progress
  local line_count=$(wc -l <"$txt_file" 2>/dev/null || echo "0")
  if [ "$line_count" -gt 10000 ]; then
    echo "Processed: $txt_file -> $json_file (total $line_count lines)"
  else
    echo "Processed: $txt_file -> $json_file"
  fi
}

# Export function for xargs usage
export -f process_file_with_awk

# Use find + xargs to process all txt files in parallel
echo "Starting parallel processing, using $PARALLEL_JOBS parallel jobs..."

find build/text -name "*.txt" -type f |
  xargs -P "$PARALLEL_JOBS" -I {} bash -c 'process_file_with_awk "$@"' _ {}

echo "JSON conversion completed! All txt files have been converted to JSON format."
