#!/usr/bin/env bash
#
# setup.sh — set up the Qwen 3.8 Flash-Next Strix Halo stack (see README.md).
#
#   precheck   tools, docker, /dev/kfd, kernel args, free disk
#   clone      EngramHalo.cpp — the build context for the compose images
#   key        create ./.api-key (0600)
#   weights    IQ4_XS model + MTP draft heads + mmproj  (~100 GB)
#   verify     every file against the sizes Hugging Face reports
#
#   ./setup.sh                      # everything; asks before the big download
#   ./setup.sh --yes                # unattended
#   ./setup.sh --check              # status only, change nothing
#   ./setup.sh --steps key,weights  # subset (precheck and verify always run)
#   ./setup.sh --quant UD-Q3_K_XL   # different quantisation
#   ./setup.sh --checksum           # sha256 the weights too (~100 GB of reads)
#
# Files land in <MODELS_DIR>/<repo>/<path>, the layout docker-compose.yaml mounts
# read-only at /models. Files already present at the expected size are skipped, so
# an interrupted run resumes where it stopped.
#
# Needs bash 4.2+, curl, git, sha256sum and the `hf` CLI. No jq, no python.

set -euo pipefail

# Numeric parsing must not depend on the locale: EPOCHREALTIME and printf use the
# locale decimal separator, which is a comma in many locales and breaks arithmetic.
export LC_NUMERIC=C

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------- configuration
GIT_URL="https://github.com/Aristo94/EngramHalo.cpp.git"
GIT_BRANCH="strix-halo-qwen4exp"
HF_MAIN="unsloth/Qwen3.8-Flash-Next-GGUF"
HF_MTP="EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF"
MTP_FILE="mtp-Qwen3.8-Flash-Next-Q8_0.gguf"
# FR-Spec MTP head used by the --profile drluoto benchmark (drluoto/llama.cpp).
HF_MTP_FR="drluoto/Qwen3.8-Flash-Next-MTP-GGUF"
MTP_FR_FILE="mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf"
MMPROJ_FILE="mmproj-BF16.gguf"
QUANT="UD-IQ4_XS"
MODELS_DIR="${HOME}/Models"
CLONE_DIR="${SELF_DIR}/EngramHalo.cpp"
KEY_FILE="${SELF_DIR}/.api-key"
HF_BIN="hf"
KERNEL_ARGS=(amd_iommu=off amdgpu.gttsize= ttm.pages_limit=)

CHECK=0 DRY=0 ASSUME_YES=0 CHECKSUM=0 FORCE=0 FULL_CLONE=0
SELECTED=()

# ------------------------------------------------------------------- terminal
if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RST=$'\033[0m'
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m'
else
  BOLD='' DIM='' RST='' C_OK='' C_WARN='' C_FAIL=''
fi

info() { printf '  %s\n' "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RST"; }
ok()   { printf '  %sok%s    %s\n' "$C_OK" "$RST" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$C_WARN" "$RST" "$*"; }
fail() { printf '  %sfail%s  %s\n' "$C_FAIL" "$RST" "$*"; }
die()  { printf '  %sfail%s  %s\n' "$C_FAIL" "$RST" "$*" >&2; exit 1; }

STEP_NO=0
STEP_TOTAL=0
step_header() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s[%d/%d] %s%s\n' "$BOLD" "$STEP_NO" "$STEP_TOTAL" "$*" "$RST"
}

human() {
  awk -v n="${1:-0}" 'BEGIN {
    n += 0; split("B KiB MiB GiB TiB", u, " ")
    for (i = 1; i <= 5; i++) {
      if (n < 1024 || i == 5) { printf (u[i] == "B") ? "%.0f %s" : "%.1f %s", n, u[i]; exit }
      n /= 1024
    }
  }'
}

# file size in bytes. -L follows symlinks: model dirs are commonly symlinked to a
# shared store, and without it a symlink reports its own length (~100 bytes).
if stat -L -c %s . >/dev/null 2>&1; then
  fsize() { stat -L -c %s -- "$1"; }
else
  fsize() { stat -L -f %z "$1"; }
fi

now_us() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s' "${EPOCHREALTIME//[!0-9]/}"   # strip the locale decimal separator
  else
    printf '%s000000' "$(date +%s)"
  fi
}

# ------------------------------------------------------------- progress bars
# Pure bash: one line, redrawn in place on a terminal; percentage milestones
# when stderr is piped or redirected. Bars write to stderr so that command
# substitution of a function's stdout (sha256_of) is never polluted.
# bar_start <label> <total> [bytes|count] ; bar_set <done> ; bar_done
BAR_LABEL='' BAR_TOTAL=1 BAR_DONE=0 BAR_T0=0 BAR_LAST=0 BAR_NEXT=0 BAR_UNIT=bytes
bar_start() {
  BAR_LABEL="$1"
  BAR_UNIT="${2:-bytes}"
  BAR_TOTAL="${3:-1}"
  if ! [[ "$BAR_TOTAL" =~ ^[0-9]+$ ]] || ((BAR_TOTAL < 1)); then BAR_TOTAL=1; fi
  BAR_DONE=0 BAR_NEXT=0 BAR_LAST=0
  BAR_T0="$(now_us)"
  bar_set 0
}

bar_amounts() {  # rendered "done/total" for the current bar
  if [[ "$BAR_UNIT" == count ]]; then
    printf '%d/%d' "$BAR_DONE" "$BAR_TOTAL"
  else
    printf '%s/%s' "$(human "$BAR_DONE")" "$(human "$BAR_TOTAL")"
  fi
}

bar_set() {
  BAR_DONE="$1"
  local pct width=32 filled now out='' i line el_us eta_us
  pct=$(( BAR_DONE * 100 / BAR_TOTAL ))
  if ((pct > 100)); then pct=100; fi
  if [[ ! -t 2 ]]; then
    # no terminal: one line per 20% step, nothing at 0%
    if ((pct > 0 && pct >= BAR_NEXT)); then
      printf '  %s: %3d%%\n' "$BAR_LABEL" "$pct" >&2
      BAR_NEXT=$((BAR_NEXT + 20))
    fi
    return 0
  fi
  now="$(now_us)"
  if ((pct < 100)) && ((now - BAR_LAST < 100000)); then return 0; fi
  BAR_LAST="$now"
  filled=$(( width * pct / 100 ))
  for ((i = 0; i < filled; i++)); do out+='#'; done
  for ((i = filled; i < width; i++)); do out+='-'; done
  line="$(bar_amounts)"
  el_us=$(( now - BAR_T0 ))
  if ((pct >= 100)); then
    line="${line}  in $((el_us / 1000000))s"
  elif ((BAR_DONE > 0 && el_us > 250000)); then
    eta_us=$(( (BAR_TOTAL - BAR_DONE) * el_us / BAR_DONE ))
    line="${line}$(printf '  eta %d:%02d' $((eta_us / 60000000)) $(( (eta_us / 1000000) % 60 )))"
  fi
  printf '\r  %-34s [%s] %3d%%  %s   ' "$BAR_LABEL" "$out" "$pct" "$line" >&2
  return 0
}

bar_done() {
  bar_set "$BAR_TOTAL"
  if [[ -t 2 ]]; then printf '\n' >&2; fi
  return 0
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ Hugging Face API
# hf_tree <repo> [subdir] -> "<size>\t<path>" for every file in the folder
hf_tree() {
  local repo="$1" sub="${2:-}"
  curl --fail --silent --show-error --retry 3 --retry-delay 2 --max-time 90 \
    "https://huggingface.co/api/models/${repo}/tree/main${sub:+/$sub}" 2>/dev/null |
    awk '
      BEGIN { RS = ","; size = ""; isfile = 0 }
      {
        if (match($0, /"type":"(file|directory)"/)) { isfile = ($0 ~ /"type":"file"/); size = "" }
        if (isfile && size == "" && match($0, /"size":[0-9]+/))
          size = substr($0, RSTART + 7, RLENGTH - 7)
        if (isfile && size != "" && match($0, /"path":"[^"]*"/))
          print size "\t" substr($0, RSTART + 8, RLENGTH - 9)
      }'
}

# remote_sha256 <repo> <path> — the sha256 Hugging Face records for a file.
# X-Linked-ETag on the resolve URL carries the LFS sha256. The plain `etag` is the xet
# content hash (or a git blob sha1 for small files), which sha256sum never matches.
remote_sha256() {
  curl --head --location --silent --show-error --max-time 60 \
    "https://huggingface.co/$1/resolve/main/$2" 2>/dev/null |
    awk '
      tolower($0) ~ /^x-linked-etag:/ { sub(/^[^:]*:[ \t]*/, ""); v = $0 }
      tolower($0) ~ /^etag:[ \t]/     { sub(/^[^:]*:[ \t]*/, ""); e = $0 }
      END { h = (v != "" ? v : e); gsub(/[\r\n "]/, "", h); print h }'
}

# ---------------------------------------------------- manifest and local state
# manifest lines: "<remote size>\t<repo>\t<path>"; todo lines add a fourth "<why>"
WORK='' MANIFEST='' TODO='' MANIFEST_TOTAL=0 TODO_BYTES=0

build_manifest() {
  MANIFEST="${WORK}/manifest.tsv"
  TODO="${WORK}/todo.tsv"
  : > "$MANIFEST"
  info "reading file lists from huggingface.co"
  hf_tree "$HF_MAIN" "$QUANT" > "${WORK}/quant.tsv" || true
  if [[ ! -s "${WORK}/quant.tsv" ]]; then
    if hf_tree "$HF_MAIN" "" > "${WORK}/root.tsv" && [[ -s "${WORK}/root.tsv" ]]; then
      local avail
      avail=$(cut -f2 "${WORK}/root.tsv" | grep '/' | cut -d/ -f1 | sort -u | tr '\n' ' ')
      die "no ${QUANT} files in ${HF_MAIN}. Quants available: ${avail}"
    fi
    die "cannot reach huggingface.co — check the network (and HF_TOKEN for gated repos)"
  fi
  awk -F'\t' -v r="$HF_MAIN" '{ print $1 "\t" r "\t" $2 }' "${WORK}/quant.tsv" >> "$MANIFEST"
  hf_tree "$HF_MAIN" "" > "${WORK}/root.tsv" || true
  awk -F'\t' -v r="$HF_MAIN" -v f="$MMPROJ_FILE" '$2 == f { print $1 "\t" r "\t" $2 }' "${WORK}/root.tsv" >> "$MANIFEST"
  hf_tree "$HF_MTP" "" > "${WORK}/mtp.tsv" || true
  awk -F'\t' -v r="$HF_MTP" -v f="$MTP_FILE" '$2 == f { print $1 "\t" r "\t" $2 }' "${WORK}/mtp.tsv" >> "$MANIFEST"
  hf_tree "$HF_MTP_FR" "" > "${WORK}/mtp-fr.tsv" || true
  awk -F'\t' -v r="$HF_MTP_FR" -v f="$MTP_FR_FILE" '$2 == f { print $1 "\t" r "\t" $2 }' "${WORK}/mtp-fr.tsv" >> "$MANIFEST"
  [[ -s "$MANIFEST" ]] || die "could not read the file list for ${HF_MAIN} (${QUANT})"
  MANIFEST_TOTAL=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$MANIFEST")
  ok "$(awk 'END { print NR }' "$MANIFEST") files expected, $(human "$MANIFEST_TOTAL")"
}

scan_local() {
  : > "$TODO"
  local n=0 n_ok=0 n_bad=0 bytes_ok=0
  TODO_BYTES=0
  bar_start "scanning ${MODELS_DIR}" count "$(awk 'END { print NR }' "$MANIFEST")"
  while IFS=$'\t' read -r size repo path; do
    n=$((n + 1))
    bar_set "$n"
    local lp why=''
    lp="${MODELS_DIR}/${repo}/${path}"
    if [[ ! -f "$lp" ]]; then
      why='missing'
    elif [[ $FORCE -eq 1 ]]; then
      why='--force'
    elif [[ "$(fsize "$lp")" != "$size" ]]; then
      why="$(human "$(fsize "$lp")") of $(human "$size")"
    fi
    if [[ -n "$why" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$size" "$repo" "$path" "$why" >> "$TODO"
      TODO_BYTES=$((TODO_BYTES + size))
      n_bad=$((n_bad + 1))
    else
      n_ok=$((n_ok + 1))
      bytes_ok=$((bytes_ok + size))
    fi
  done < "$MANIFEST"
  bar_done
  ok "${n_ok} in place ($(human "$bytes_ok")), ${n_bad} to fetch ($(human "$TODO_BYTES"))"
}

# sha256 of a file, with a bar fed from /proc/<pid>/io while sha256sum runs
sha256_of() {
  local file="$1" size="$2" pid r
  if [[ ! -r /proc/self/io ]]; then
    note "hashing $(basename -- "$1") ($(human "$size")), this takes a while" >&2
    sha256sum -- "$1" | cut -d' ' -f1
    return
  fi
  bar_start "sha256 $(basename -- "$1")" bytes "$size"
  sha256sum -- "$file" > "${WORK}/sha.out" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    r=$(awk '/^rchar/ { print $2; exit }' "/proc/${pid}/io" 2>/dev/null || true)
    if [[ -n "$r" ]]; then bar_set "$r"; fi
    sleep 0.2
  done
  wait "$pid"
  bar_done
  cut -d' ' -f1 < "${WORK}/sha.out"
}

# ---------------------------------------------------------------- the steps
step_precheck() {
  step_header "precheck — tools, GPU, disk"
  build_manifest
  scan_local
  local bad=0 c
  for c in curl git awk sha256sum "$HF_BIN"; do
    if need_cmd "$c"; then
      ok "$c ${DIM}$(command -v "$c")${RST}"
    elif [[ "$c" == "$HF_BIN" ]]; then
      bad=1
      fail "$c not on PATH — install the Hugging Face CLI (pip install huggingface_hub)"
    else
      bad=1
      fail "$c not on PATH"
    fi
  done
  if need_cmd docker; then
    if docker info >/dev/null 2>&1; then
      local ver
      ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
      if [[ -z "${ver:-}" ]]; then ver=$(docker version --format '{{.Version}}' 2>/dev/null | tail -1); fi
      ok "docker daemon ${ver:-running}"
    else
      warn "docker is installed but the daemon is not answering"
    fi
  else
    warn "docker not found — the compose step will not work on this host"
  fi
  if [[ "$(uname -m)" != "x86_64" ]]; then
    warn "arch is $(uname -m); this stack targets x86_64 Strix Halo"
  fi
  if [[ -c /dev/kfd ]]; then
    ok "/dev/kfd present"
  else
    warn "/dev/kfd missing — ROCm profiles cannot run on this host"
  fi
  local a absent=()
  if [[ -r /proc/cmdline ]]; then
    for a in "${KERNEL_ARGS[@]}"; do
      if ! grep -q -- "$a" /proc/cmdline; then absent+=("$a"); fi
    done
    if ((${#absent[@]})); then
      warn "kernel args not set: ${absent[*]} — see README (/etc/default/grub)"
    else
      ok "kernel GTT args set"
    fi
  else
    note "/proc/cmdline not readable — kernel arg check skipped"
  fi
  local probe="$MODELS_DIR" free
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname -- "$probe")"; done
  free=$(df -P -k "$probe" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')
  if [[ -z "${free:-}" ]]; then
    warn "could not read free space for $probe"
  elif ((free < TODO_BYTES)); then
    bad=1
    fail "$(human "$free") free at ${probe}, $(human "$TODO_BYTES") needed"
  else
    ok "$(human "$free") free at ${probe} ($(human "$TODO_BYTES") needed)"
  fi
  if [[ $bad -ne 0 ]]; then die "precheck failed"; fi
}

step_clone() {
  step_header "clone EngramHalo.cpp -> ${CLONE_DIR}"
  local cur
  if [[ -d "$CLONE_DIR" ]]; then
    if [[ -d "${CLONE_DIR}/.git" ]]; then
      cur=$(git -C "$CLONE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
      if [[ "$cur" == "$GIT_BRANCH" ]]; then
        ok "already checked out on ${cur}"
      else
        warn "${CLONE_DIR} is on '${cur}', expected '${GIT_BRANCH}'"
      fi
      return 0
    fi
    die "${CLONE_DIR} exists but is not a git checkout"
  fi
  if [[ $CHECK -eq 1 || $DRY -eq 1 ]]; then
    info "would clone ${GIT_URL} (${GIT_BRANCH}) -> ${CLONE_DIR}"
    return 0
  fi
  local -a cmd=(git clone --branch "$GIT_BRANCH" --single-branch --progress)
  if ((FULL_CLONE == 0)); then cmd+=(--depth 1); fi
  info "${DIM}${GIT_URL} ${GIT_BRANCH}$([[ $FULL_CLONE -eq 0 ]] && echo ' shallow')${RST}"
  if ! "${cmd[@]}" "$GIT_URL" "$CLONE_DIR"; then die "git clone failed"; fi
  ok "${CLONE_DIR} ready"
}

step_key() {
  step_header "API key -> ${KEY_FILE}"
  if [[ -f "$KEY_FILE" ]]; then
    if [[ -s "$KEY_FILE" ]]; then
      ok "$(basename -- "$KEY_FILE") already exists ($(human "$(fsize "$KEY_FILE")"))"
      if [[ "$(stat -c %a -- "$KEY_FILE" 2>/dev/null || echo 600)" != "600" ]]; then
        if [[ $CHECK -eq 0 && $DRY -eq 0 ]]; then chmod 600 -- "$KEY_FILE"; fi
        ok "permissions set to 600"
      fi
      return 0
    fi
    die "${KEY_FILE} exists but is empty"
  fi
  if [[ $CHECK -eq 1 || $DRY -eq 1 ]]; then
    info "would write ${KEY_FILE} (0600)"
    return 0
  fi
  (
    umask 077
    if need_cmd openssl; then openssl rand -base64 48; else head -c 48 /dev/urandom | base64; fi
  ) > "$KEY_FILE" || die "could not write ${KEY_FILE}"
  ok "$(basename -- "$KEY_FILE") written (0600) — keep it out of git"
}

step_weights() {
  step_header "weights -> ${MODELS_DIR}"
  if [[ ! -s "$TODO" ]]; then
    ok "every file is already here at the expected size — nothing to download"
    return 0
  fi
  info "$(awk 'END { print NR }' "$TODO") file(s) to fetch ($(human "$TODO_BYTES"))"
  local size repo path why
  while IFS=$'\t' read -r size repo path why; do
    info "$(printf '%-58s %10s  %s' "$(basename -- "$path")" "$(human "$size")" "$why")"
  done < "$TODO"
  if [[ $CHECK -eq 1 || $DRY -eq 1 ]]; then
    note "would run: ${HF_BIN} download <repo> <files> --local-dir ${MODELS_DIR}/<repo>"
    return 0
  fi
  if [[ $ASSUME_YES -eq 0 ]]; then
    printf '  Download %s into %s? [y/N] ' "$(human "$TODO_BYTES")" "$MODELS_DIR"
    read -r reply || reply=''
    case "$reply" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
  fi
  if [[ ! -d "$MODELS_DIR" ]]; then mkdir -p -- "$MODELS_DIR"; fi
  local repo_list repo files t0
  while read -r repo; do repo_list+=("$repo"); done < <(awk -F'\t' '{ print $2 }' "$TODO" | awk '!seen[$0]++')
  for repo in "${repo_list[@]}"; do
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(awk -F'\t' -v r="$repo" '$2 == r { print $3 }' "$TODO")
    info "${repo} (${#files[@]} file(s))"
    t0=$(date +%s)
    # hf draws its own per-file bars: let it own the terminal
    if ! "$HF_BIN" download "${repo}" "${files[@]}" --local-dir "${MODELS_DIR}/${repo}"; then
      die "hf download failed for ${repo} — re-run this script to resume"
    fi
    ok "${repo} in $(( $(date +%s) - t0 ))s"
  done
  ok "downloads finished"
}

step_verify() {
  step_header "verify against Hugging Face"
  local size repo path lp why want got bad=0 bytes=0 i=0 nohash=0
  local total
  total=$(awk 'END { print NR }' "$MANIFEST")
  : > "${WORK}/bad.tsv"
  bar_start "verify" count "$total"
  while IFS=$'\t' read -r size repo path; do
    lp="${MODELS_DIR}/${repo}/${path}"
    why=''
    if [[ ! -f "$lp" ]]; then
      why='missing'
    elif [[ "$(fsize "$lp")" != "$size" ]]; then
      why="$(human "$(fsize "$lp")") of $(human "$size")"
    elif [[ $CHECKSUM -eq 1 ]]; then
      want=$(remote_sha256 "$repo" "$path")
      if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        nohash=$((nohash + 1)) # nothing comparable published for this file
      else
        got=$(sha256_of "$lp" "$size")
        if [[ "$got" != "$want" ]]; then why='sha256 mismatch'; fi
      fi
    fi
    if [[ -n "$why" ]]; then
      bad=$((bad + 1))
      printf '%s\t%s\t%s\n' "$size" "$path" "$why" >> "${WORK}/bad.tsv"
    fi
    bytes=$((bytes + size))
    i=$((i + 1))
    bar_set "$i"
  done < "$MANIFEST"
  bar_done
  if ((bad > 0)); then
    while IFS=$'\t' read -r size path why; do fail "$(basename -- "$path"): ${why}"; done < "${WORK}/bad.tsv"
    die "verify failed — re-run this script to resume the download"
  fi
  ok "${total} files, $(human "$bytes") in place"
  if [[ $CHECKSUM -eq 0 ]]; then
    note "sizes checked only — --checksum also compares sha256"
  elif ((nohash > 0)); then
    note "${nohash} file(s) had no sha256 published by the hub and were size-checked only"
  fi
}

# ----------------------------------------------------------------------- main
usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c | --check) CHECK=1; shift ;;
    -n | --dry-run) DRY=1; shift ;;
    -y | --yes) ASSUME_YES=1; shift ;;
    -q | --quant) QUANT="${2:?--quant needs a value}"; shift 2 ;;
    -m | --models-dir) MODELS_DIR="${2:?--models-dir needs a path}"; shift 2 ;;
    -s | --steps)
      IFS=',' read -ra steps_split <<< "${2:?--steps needs a value}"
      SELECTED+=("${steps_split[@]}")
      shift 2
      ;;
    --key-file) KEY_FILE="${2:?--key-file needs a path}"; shift 2 ;;
    --clone-dir) CLONE_DIR="${2:?--clone-dir needs a path}"; shift 2 ;;
    --hf-bin) HF_BIN="${2:?--hf-bin needs a command}"; shift 2 ;;
    --checksum) CHECKSUM=1; shift ;;
    --force) FORCE=1; shift ;;
    --full-clone) FULL_CLONE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

if [[ $CHECK -eq 1 ]]; then DRY=1; fi

DEFAULT_STEPS=(clone key weights)
if ((${#SELECTED[@]} == 0)); then SELECTED=(clone key weights); fi

for s in "${SELECTED[@]}"; do
  case "$s" in
    clone | key | weights) ;;
    *) die "unknown step '${s}' — pick from clone, key, weights" ;;
  esac
done

RUN=()
for s in "${SELECTED[@]}"; do
  duplicate=0
  if ((${#RUN[@]})); then
    for r in "${RUN[@]}"; do
      if [[ "$r" == "$s" ]]; then duplicate=1; fi
    done
  fi
  if [[ $duplicate -eq 0 ]]; then RUN+=("$s"); fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qwen-setup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PLAN=(precheck "${RUN[@]}" verify)
STEP_TOTAL=$(( ${#PLAN[@]} ))

printf '%sQwen 3.8 Flash-Next setup%s\n' "$BOLD" "$RST"
note "repo   ${SELF_DIR}"
note "models ${MODELS_DIR}"
note "quant ${QUANT}  branch ${GIT_BRANCH}"

for s in "${PLAN[@]}"; do
  case "$s" in
    precheck)
      if ! need_cmd curl; then die "curl not on PATH"; fi
      step_precheck
      ;;
    clone)   step_clone ;;
    key)     step_key ;;
    weights) step_weights ;;
    verify)  step_verify ;;
  esac
done

if [[ $CHECK -eq 1 ]]; then
  printf '\n%sNothing changed (--check).%s\n' "$BOLD" "$RST"
elif [[ $DRY -eq 1 ]]; then
  printf '\n%sNothing ran (--dry-run).%s\n' "$BOLD" "$RST"
else
  printf '\n%sSetup complete.%s Next:\n' "$BOLD" "$RST"
  printf '  docker compose build --profile long\n'
  printf '  docker compose --profile long up -d\n'
  printf '  docker logs -f qwen38-flash-next-qwen-long-1\n'
fi
