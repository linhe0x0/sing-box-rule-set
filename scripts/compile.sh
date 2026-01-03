#!/usr/bin/env bash
set -e

# Ensure output directory exists
rm -rf build/srs
mkdir -p build/srs

# Get CPU core count for parallel processing
if command -v nproc >/dev/null 2>&1; then
  PARALLEL_JOBS=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  PARALLEL_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo "8")
else
  PARALLEL_JOBS=8
fi

# Check if there are JSON files to compile
JSON_COUNT=$(find build/json -name "*.json" -type f 2>/dev/null | wc -l)
if [ "$JSON_COUNT" -eq 0 ]; then
  echo "Warning: No JSON files found, skipping SRS compilation step."
  exit 0
fi

# Check if sing-box is available
if ! command -v sing-box >/dev/null 2>&1; then
  echo "Warning: sing-box command not found, skipping SRS compilation step. Please install sing-box first." >&2
  exit 0
fi

# Compile JSON files to SRS files
# Parameters: $1 = input JSON file path
compile_json_to_srs() {
  local json_file="$1"
  local filename=$(basename -- "$json_file")
  local filename_noext="${filename%.*}"
  local srs_file="build/srs/${filename_noext}.srs"

  # Use sing-box to compile JSON to SRS
  if sing-box rule-set compile "$json_file" -o "$srs_file" 2>build/srs/"${filename_noext}.srs.err"; then
    echo "Compiled: $json_file -> $srs_file"
    # Compilation successful, remove corresponding error log if exists
    rm -f build/srs/"${filename_noext}.srs.err"
  else
    echo "Compilation failed: $json_file" >&2
    echo "Error details:" >&2
    cat build/srs/"${filename_noext}.srs.err" >&2
    return 1
  fi
}

# Export function for xargs usage
export -f compile_json_to_srs

# Use find + xargs to process all JSON files in parallel
# Temporarily disable set -e to allow partial compilation failures without affecting overall process
set +e
echo "Starting JSON to SRS compilation, using $PARALLEL_JOBS parallel jobs..."

find build/json -name "*.json" -type f |
  xargs -P "$PARALLEL_JOBS" -I {} bash -c 'compile_json_to_srs "$@"' _ {}

COMPILE_EXIT_CODE=$?

# Restore set -e
set -e

if [ "$COMPILE_EXIT_CODE" -eq 0 ]; then
  echo "All JSON files have been successfully compiled to SRS format."
else
  echo "Warning: Some JSON files failed to compile, please check the error messages above." >&2
fi
