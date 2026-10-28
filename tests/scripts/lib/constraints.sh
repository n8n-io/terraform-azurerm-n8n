# shellcheck shell=bash
# constraints.sh: version helpers for tests/scripts/check-version-drift.sh,
# split into a sourceable file so tests/scripts/test-version-drift-constraints.sh
# can exercise them offline (the drift script itself makes network calls at
# the top level and cannot be sourced by a test). Sourced only.
#
# Same idea and exit-code contract as the sibling modules' constraints.sh
# (n8n-io/terraform-google-n8n#40, n8n-io/terraform-aws-n8n#196), written in
# plain bash plus jq instead of python3 so this repo's drift tooling needs
# only bash, curl, jq, and helm. bash 3.2 compatible (macOS /bin/bash): no
# associative arrays, no `local -n`.

# Plain numeric N[.N[.N]], at most nine digits per part so 10# arithmetic
# cannot overflow.
_DRIFT_VERSION_RE='^[0-9]{1,9}(\.[0-9]{1,9}){0,2}$'

# _drift_pad <N[.N[.N]]>: prints three space-separated parts, missing parts 0.
_drift_pad() {
  local a b c
  IFS=. read -r a b c <<<"$1"
  echo "$((10#${a:-0})) $((10#${b:-0})) $((10#${c:-0}))"
}

# _drift_cmp <a> <b>: prints -1, 0, or 1. Both must already match
# _DRIFT_VERSION_RE.
_drift_cmp() {
  local a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 <<<"$(_drift_pad "$1")"
  read -r b1 b2 b3 <<<"$(_drift_pad "$2")"
  if ((a1 != b1)); then ((a1 < b1)) && echo -1 || echo 1; return; fi
  if ((a2 != b2)); then ((a2 < b2)) && echo -1 || echo 1; return; fi
  if ((a3 != b3)); then ((a3 < b3)) && echo -1 || echo 1; return; fi
  echo 0
}

# constraint_accepts <constraint> <version>
# Exit 0 when <version> satisfies the Terraform version constraint, 1 when it
# does not, 2 when the constraint or <version> cannot be parsed. The
# constraint is comma separated; each part is an operator (~>, >=, >, <=, <,
# !=, =, or none, meaning =) and a numeric N[.N[.N]] version. A prerelease or
# build-metadata version, in the constraint or as <version>, is exit 2, so the
# caller reports an explicit ERROR instead of guessing. Terraform's rule that
# an exact constraint cannot be combined with another is not enforced: the
# constraints this reads come from versions.tf, which Terraform validates.
#
# ~> follows Terraform's pessimistic operator: only the rightmost given part
# may grow. "~> 3.0" admits 3.x.y, "~> 1.2.3" admits 1.2.z, and "~> 1"
# admits 1.x.y.
constraint_accepts() {
  local constraint="$1" version="$2"
  local part_re='^(~>|>=|<=|!=|>|<|=)?[[:space:]]*([0-9]{1,9}(\.[0-9]{1,9}){0,2})$'
  [[ "$version" =~ $_DRIFT_VERSION_RE ]] || return 2
  # `read -a` silently drops one trailing empty field, so a trailing comma
  # would otherwise parse as valid.
  [[ "$constraint" =~ ,[[:space:]]*$ ]] && return 2

  local -a parts
  IFS=, read -r -a parts <<<"$constraint"
  ((${#parts[@]} > 0)) || return 2

  local ok=0 part op lim cmp upper n l1 l2
  for part in "${parts[@]}"; do
    # Trim surrounding whitespace.
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ "$part" =~ $part_re ]] || return 2
    op="${BASH_REMATCH[1]:-=}"
    lim="${BASH_REMATCH[2]}"
    cmp="$(_drift_cmp "$version" "$lim")"
    case "$op" in
      "=") [[ "$cmp" == 0 ]] || ok=1 ;;
      "!=") [[ "$cmp" != 0 ]] || ok=1 ;;
      ">=") [[ "$cmp" != -1 ]] || ok=1 ;;
      ">") [[ "$cmp" == 1 ]] || ok=1 ;;
      "<=") [[ "$cmp" != 1 ]] || ok=1 ;;
      "<") [[ "$cmp" == -1 ]] || ok=1 ;;
      "~>")
        [[ "$cmp" != -1 ]] || ok=1
        n="$(awk -F. '{ print NF }' <<<"$lim")"
        IFS=. read -r l1 l2 _ <<<"$lim"
        if ((n < 3)); then
          upper="$((10#$l1 + 1))"
        else
          upper="$((10#$l1)).$((10#$l2 + 1))"
        fi
        [[ "$(_drift_cmp "$version" "$upper")" == -1 ]] || ok=1
        ;;
    esac
  done
  return "$ok"
}

# provider_records <versions.tf>
# Prints one "name|source|constraint" line per required_providers entry, in
# file order. Handles the multi-line form `terraform fmt` writes and the
# one-line form it also accepts (`helm = { source = "...", version = "..." }`),
# including a closing brace on the version line. An attribute that is not
# found is printed empty, so the caller reports an explicit ERROR instead of
# attributing one entry's source or constraint to another. Comments are
# removed first (`#` and `//` to end of line, `/* ... */` within or across
# lines), since attributes are matched anywhere on a line. A comment marker
# inside a quoted value is not recognized as such; no provider source or
# version constraint contains one.
provider_records() {
  awk '
    function strip(line,   out, s, lc, d) {
      out = ""
      while (line != "") {
        if (in_bc) {
          s = index(line, "*/")
          if (!s) return out
          line = substr(line, s + 2)
          in_bc = 0
          continue
        }
        s = index(line, "/*")
        lc = index(line, "#")
        d = index(line, "//")
        if (d && (!lc || d < lc)) lc = d
        if (lc && (!s || lc < s)) return out substr(line, 1, lc - 1)
        if (!s) return out line
        out = out substr(line, 1, s - 1) " "
        line = substr(line, s + 2)
        in_bc = 1
      }
      return out
    }
    function attr(line, key,   s) {
      if (!match(line, "(^|[{,[:space:]])" key "[[:space:]]*=[[:space:]]*\"[^\"]*\"")) return ""
      s = substr(line, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", s)
      sub(/"$/, "", s)
      return s
    }
    function grab(line) {
      if ((v = attr(line, "source")) != "") src = v
      if ((v = attr(line, "version")) != "") ver = v
    }
    { $0 = strip($0) }
    !in_rp && /required_providers[[:space:]]*\{/ { in_rp = 1; next }
    in_rp && !in_p && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\{/ {
      name = $0
      sub(/^[[:space:]]*/, "", name)
      sub(/[[:space:]]*=.*$/, "", name)
      src = ""; ver = ""; in_p = 1
      rest = $0
      sub(/^[^{]*\{/, "", rest)
      grab(rest)
      if (rest ~ /\}/) { print name "|" src "|" ver; in_p = 0 }
      next
    }
    in_p {
      grab($0)
      if ($0 ~ /\}/) { print name "|" src "|" ver; in_p = 0 }
      next
    }
    in_rp && /^[[:space:]]*\}/ { in_rp = 0 }
  ' "$1"
}

# aks_classify <listed> <is_eol> <days until EOL> <warn days>
# Classifies one aks_release_status answer for the pinned AKS minor. Prints
# one of: unlisted (endoflife.date does not list the pin), eol (past end of
# life, by flag or by date), no-eol-date (no published end-of-life date),
# near-eol (end of life within <warn days>, inclusive), or supported.
aks_classify() {
  local listed="$1" is_eol="$2" days="$3" warn="$4"
  if [[ "$listed" != "true" ]]; then
    echo unlisted
  elif [[ "$is_eol" == "true" || "$days" =~ ^-[0-9]+$ ]]; then
    echo eol
  elif [[ ! "$days" =~ ^[0-9]{1,9}$ ]]; then
    echo no-eol-date
  elif ((10#$days <= warn)); then
    echo near-eol
  else
    echo supported
  fi
}

# latest_release
# Reads candidate versions or tags on stdin, one per line, and prints the
# highest plain X.Y.Z release. Prereleases (5.10.0-beta1), build metadata,
# and non-version tags (an OCI registry's `artifacthub.io` or `sha256-...`
# tags) are dropped rather than compared, since none of them is the latest
# release. A single leading "v" (GitHub release tags) is stripped first.
# Exit 1 with nothing printed when no line qualifies.
latest_release() {
  local latest
  latest="$(sed 's/\r$//; s/^v//' \
    | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n 1)"
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

# aks_release_status <pinned> <today YYYY-MM-DD>
# Reads the endoflife.date v1 product JSON for azure-kubernetes-service on
# stdin. Prints one tab-separated line:
#   <newest GA minor> <pinned minor listed: true|false> <pinned isEol> <pinned eolFrom> <days until eolFrom>
# The newest GA minor is the highest release whose releaseDate is on or
# before <today>, so a release endoflife.date lists ahead of GA is not
# reported as the latest. <pinned> may carry a patch (1.35.6); only its
# minor is looked up. Exit 1 with nothing printed on unparseable input or
# when no release qualifies as GA.
aks_release_status() {
  local pinned="$1" today="$2" minor
  minor="$(awk -F. '{ print $1 "." $2 }' <<<"$pinned")"
  jq -er --arg pin "$minor" --arg today "$today" '
    def ver: split(".") | map(tonumber);
    def epoch: . + "T00:00:00Z" | fromdateiso8601;
    .result.releases as $r
    | ([$r[] | select(.releaseDate != null and .releaseDate <= $today)]
        | sort_by(.name | ver) | last | .name) as $latest
    | select($latest != null)
    | (first($r[] | select(.name == $pin)) // null) as $p
    | [
        $latest,
        ($p != null),
        ($p.isEol // false),
        ($p.eolFrom // ""),
        (if ($p.eolFrom // null) == null then ""
         else ((($p.eolFrom | epoch) - ($today | epoch)) / 86400 | floor)
         end)
      ]
    | map(tostring) | join("\t")
  ' 2>/dev/null
}
