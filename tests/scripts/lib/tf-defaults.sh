# shellcheck shell=bash
# tf-defaults.sh: shared helper for scripts that need a variable's literal
# `default =` value straight out of a `.tf` file, without a Terraform
# init/plan cycle. Intentionally text-based (awk), not `terraform console`:
# several callers (chart-values-diff.sh, check-version-drift.sh) run before
# `terraform init` and must not require provider credentials or a state
# file. Sourced only; not meant to be executed directly.
#
# Usage: read_default <file> <variable_name>
# Prints the default value with surrounding quotes stripped, or nothing
# (empty string, exit 0) if the variable or its default is not found.
read_default() {
  local file="$1"
  local name="$2"
  awk -v name="$name" '
    $0 ~ "variable \"" name "\" \\{" { in_var = 1; depth = 1; next }
    in_var {
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if ($0 ~ /^[[:space:]]*default[[:space:]]*=/) {
        line = $0
        sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
      if (depth <= 0) { exit }
    }
  ' "$file"
}
